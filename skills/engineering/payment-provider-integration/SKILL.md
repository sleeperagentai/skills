---
name: payment-provider-integration
description: "Wire Stripe/Paddle. Adapter, replay-safe webhooks."
---

# Payment-provider integration

Payment integrations have a known shape: an adapter interface for one provider today and another tomorrow, hosted-checkout + hosted-portal (never DIY card entry), a webhook pipe that is idempotent against provider retries, and plan/credit side-effects that are replay-safe. Follow this layout the first time; it stays small and avoids reshaping later.

## Standing rules (always on)

- **Adapter interface pattern, mandatory.** Provider-neutral `Provider` interface and generic types (`Customer`, `CheckoutSession`, `PortalSession`, `WebhookEvent`) live in `services/billing/`. The vendor code (`services/billing/<vendor>/`) is the ONLY place that knows about the vendor. Adding a second provider = new subpackage + one branch at wire-up, nothing else changes.
- **Save the `provider` discriminator on every row.** `billing_customers`, `billing_subscriptions`, `billing_events`, and every credit-lot touched by a webhook carry `provider TEXT NOT NULL`. Row origin is visible in logs; multi-provider rows coexist without migration.
- **Idempotent webhook side-effects.** Every mutating event stores `(provider, provider_event_id)` with a UNIQUE constraint and `ON CONFLICT DO NOTHING`. Credit-granting events additionally stamp `provider_event_id` on the lot itself under a PARTIAL unique index (`WHERE provider_event_id IS NOT NULL`) so replays return the existing lot instead of granting a second one.
- **Hosted checkout + hosted portal only.** Never collect card details yourself. Checkout/portal are redirects to provider-hosted URLs; the server returns `{redirectUrl}` and the client does a top-level `window.location.assign`.
- **Server owns return URLs.** The client sends a RELATIVE path (`successPath: "/settings/plan?paid=1"`); the server joins against the trusted `APP_BASE_URL`. Reject anything that isn't a leading-slash relative path — including `//foo`, which browsers treat as scheme-relative absolute (open redirect).
- **Plan flip gates on status.** Flip `workspaces.plan` ONLY when the subscription status is `active` or `trialing`. `incomplete`, `past_due`, `unpaid` leave the plan at its prior value — payment hasn't landed yet.
- **Catalog is locked BEFORE writing migration code.** Prices, cadences, yearly-discount %, rounding, credits-per-period, pack SKUs, pack expiry, signup-bonus size are all decided with the user up front. See `references/catalog-locking-questions.md`. These numbers hard-code into migration/CHECK constraints and are painful to change later.
- **Raw HTTP for the thin PRs; vendor SDK once you need typed events or paginated reads.** Checkout/Portal/Customer + HMAC webhook verify are three POSTs plus stdlib `crypto/hmac` — raw `net/http` wins, no transitive deps. Switch to the SDK the moment you need invoice iteration (`.List().Iter()`), `expand[]=...` field hydration, or typed event payloads instead of `map[string]any` + `.(string)` assertions on `event.Data.Object`. Keep the switch inside the adapter subpackage — the `Provider` interface and generic event types do not change.
- **UI stays provider-neutral.** No vendor names, no price-id surfaces, no model pickers. Buttons say "Upgrade to Creator — $49/mo" and "Manage billing", not "Stripe Checkout". The backend picks the provider; the UI picks plan + cadence.
- **Three sequential PRs — merge between.** PR1 scaffolding + webhook verify (no money moves). PR2 Checkout + Portal + subscription flow end-to-end. PR3 one-time packs + invoice download. Each merges before the next starts; the user has specified this cadence for billing-shaped work.
- **Env defaults the feature OFF.** `BILLING_ENABLED=false` out of the box; any pre-existing "free credits per day" job gets gated on its own `FREE_DAILY_ENABLED=false` so the mix of free-and-paid can be reasoned about one at a time.

## Procedure

### PR1 — Scaffolding + webhook verify

1. Lock catalog with the user — `references/catalog-locking-questions.md` is the checklist. One decision table in the plan doc.
2. Add config: `BILLING_ENABLED`, `APP_BASE_URL`, provider secret, webhook secret, one price-id env per plan+cadence and per pack. One `FREE_DAILY_ENABLED=false` if the codebase has an existing daily-grant job.
3. Package layout mirrors existing provider-neutral code (e.g. `services/email` + `services/email/<vendor>`): parent = contracts (`Provider` interface, catalog, event-type constants), subpackage = vendor adapter.
4. Migration — three tables, all with `provider` discriminator:
   - `billing_customers (PK workspace_id+provider, UNIQUE provider+provider_customer_id)`
   - `billing_subscriptions (PK provider+provider_subscription_id, idx on workspace_id+status)`
   - `billing_events (PK provider+provider_event_id, event_type, payload JSONB, received_at, processed_at NULL, error NULL, idx WHERE processed_at IS NULL for ops reconciliation)`
   Platform-scoped (webhooks arrive pre-auth across workspaces). Owner pool, not RLS-scoped.
5. Adapter stubs return `ErrNotImplemented` from Checkout/Portal/Customer in PR1; webhook sig-verify + event parse are the only live methods. HMAC-SHA256 on the `<vendor>-Signature` header, timestamp skew ≤ 5 min.
6. Webhook route `POST /webhooks/billing/{provider}` is PUBLIC (pre-auth) — same convention as email webhooks.
7. Catalog read endpoint `GET /billing/plan` returns `{current, catalog, packs, provider, asOf}` with an `available` flag per plan/cadence/pack reflecting whether its price-id env is set.

### PR2 — Checkout + Portal + plan flip + subscription credits

1. `POST /billing/checkout` body `{kind: subscription|pack, planId|packId, cadence, successPath, cancelPath}`. Server-side URL join against `APP_BASE_URL`; `isSafeReturnPath` rejects empty, non-slash-leading, and `//*`.
2. `POST /billing/portal` body `{returnPath}`. 404 if no `billing_customers` row.
3. Adapter: raw-HTTP form POSTs to `/v1/checkout/sessions`, `/v1/billing_portal/sessions`, `/v1/customers`. Set `Idempotency-Key: customer:<workspace_id>` on customer creation so a race or retry can't produce duplicates.
4. Reuse an existing customer on repeat checkout — look up `billing_customers` by `(workspace_id, provider)` before creating.
5. Dispatcher branches (the provider-neutral function; vendor code never touches the DB):
   - `checkout.completed (subscription)` → upsert customer. DO NOT flip plan here; price id is not reliable on this event. Wait for `subscription.updated`.
   - `subscription.updated` → upsert subscription row; flip plan iff status ∈ {`active`, `trialing`}.
   - `subscription.deleted` → mark cancelled, flip workspace plan to `free`.
   - `invoice.paid` → grant `creditsPerPeriod` (×12 for yearly on the single annual invoice) via `GrantIdempotent(provider_event_id)` with `expires_at = current_period_end`. Lot kind = `subscription`.
   - `invoice.failed` → log only. Status events drive plan state.
6. `GrantIdempotent` on the Postgres ledger: SELECT by `provider_event_id`; if present, return existing lot with `replayed=true`; else INSERT the lot stamped with the event id. Handle unique-violation races by re-SELECTing and returning `replayed=true`. The PARTIAL unique index means legacy NULL lots are unaffected.
7. UI: Upgrade (per plan) + Manage billing buttons. `window.location.assign(data.redirectUrl)`. No cadence toggle in PR2; default monthly. Buttons disable on `useTransition` pending.

### PR3 — Packs + invoice download

1. `invoice.paid` (one-time) → `purchase` lot, no expiry. Also idempotent via `provider_event_id`.
2. Invoice download endpoint proxies the provider's hosted invoice URL — no PDF regeneration.
3. Monthly/Yearly toggle + full plan picker.

## Pitfalls

- **Flipping the plan on `checkout.completed` leaves you with the wrong plan.** That event does not reliably carry the price id. Upsert the customer there, then flip the plan in the `subscription.updated` that follows (which does carry it). Also handles mid-period upgrades/downgrades through the same path.
- **Yearly subscriptions fire `invoice.paid` once per year, not twelve times.** Compute the credit grant as `creditsPerPeriod × 12` for yearly cadence, else the user receives 1/12th of what was sold.
- **An unqualified `UNIQUE (provider_event_id)` breaks any legacy row with NULL.** Use `CREATE UNIQUE INDEX ... WHERE provider_event_id IS NOT NULL` so historical lots without an event id don't collide on NULL.
- **`//evil.com` as a return path is an open redirect.** Browsers treat scheme-relative URLs as absolute. `isSafeReturnPath` must reject strings starting with `//` AND strings without a leading `/`.
- **A non-Postgres ledger has no UNIQUE constraints and will double-grant on replay.** In the dispatcher, type-assert `*ledger.PgStore`; if the assertion fails, log loudly and grant anyway (dev/test only). Never silently rely on it.
- **5xx on dispatch = provider retries forever.** Only persistence failure of the raw event row returns a 5xx (so the provider retries and we don't lose the event). Dispatcher failure returns 200, stamps `error` on the row, and ops reconciles via `WHERE processed_at IS NULL`.
- **`client_reference_id` is on checkout.completed only.** Set `subscription_data[metadata][workspace_id]` on the Checkout call so BOTH `checkout.completed` AND the later `subscription.updated` can resolve the workspace from the event payload.
- **Vendor signature-version header matters.** Pin a `Stripe-Version` (or equivalent) on every outbound call so a vendor-side default-version bump can't silently change the response shape under you.
- **CI red on main for unrelated reasons is NOT consent to ship billing PRs silently red.** When your PR's CI fails but the failures reproduce on `main` (unrelated lint, missing sidecar deps, etc.), surface the specific failing jobs to the user and ask whether to merge red or fix infrastructure first. Don't admin-merge without asking, and don't drag the unrelated breakage into the billing PR.
- **PR body heredocs with backticks break under `bash -c`.** `cat <<'EOF' ... backticks ... EOF` inside a `gh pr create --body "$(cat ...)"` substitution runs the shell parser over the backticks. Write the PR body to a temp file first and pass `--body-file`.
- **Don't prefill `customer_email` on Checkout if you don't need it.** The vendor collects it during Checkout and stamps the resulting customer with it, which later arrives in `subscription.updated` metadata. Prefilling means an extra DB read for a field you don't own.
- **The SDK's webhook verifier compares against real `time.Now()` and refuses on API-version mismatch — both bite tests and future-proofing.** Use the options variant (e.g. `webhook.ConstructEventWithOptions{IgnoreTolerance: true, IgnoreAPIVersionMismatch: true}`) and run your OWN timestamp check against the injected clock. Rationale: a frozen test clock cannot satisfy real-time tolerance, and a vendor API-version bump should not take production webhooks down for fields you weren't reading anyway.
- **Cross-workspace resource access returns 404, not 403.** When a webhook-provider resource id (invoice, subscription, charge) doesn't belong to the caller's workspace, respond with the same not-found shape you use for truly-missing ids. 403 confirms the id exists on the platform, which is enough to enumerate another tenant's billing history.
- **Widening the `Provider` interface silently breaks hand-rolled test mocks.** Before adding a method (ListInvoices, RefundCharge, etc.), grep the test tree for every `stubBillingProvider` / fake / mock implementor and add the new method on the same patch. The compiler catches it in the package you edited, but shards you didn't run stay broken until CI.
