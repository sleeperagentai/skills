# Third-party integration adapter pattern

Load when adding a NEW class of external vendor (payments, email provider, SMS, auth OAuth, analytics sink, …) — not when extending an existing one. The AI-gateway adapters (`services/ai-gateway/<vendor>/`) and this file converge on the same shape; the goal is that a future swap (Stripe → Paddle, Resend → Postmark) is a new subpackage and one branch, not a cross-cutting refactor.

## Shape (do not deviate)

1. **Root package = contracts only, zero vendor imports.** `services/<domain>/` holds the catalog/types, a `Provider` (or `Sender`/`Parser`) interface, provider-neutral event/result structs, and sentinel errors. Nothing in here imports a vendor SDK or an HTTP client bound to a vendor host. Existing examples: `services/email/`, `services/billing/`.
2. **One subpackage per adapter.** `services/<domain>/<vendor>/` is its own Go module with a `replace` back to the parent. The adapter imports the vendor SDK (or hand-rolls raw HTTP against the vendor API) and nothing else cares. Add both paths to `go.work` in the same commit as the first adapter — forgetting the subpackage line gives `directory prefix … does not contain modules` on `go build`.
3. **Every stored row carries a `provider TEXT NOT NULL` discriminator.** Migration tables (`<domain>_customers`, `<domain>_subscriptions`, `<domain>_events`, `<domain>_suppressions`, …) make `provider` part of the primary key or of a unique index. A workspace that migrates vendors later gets a second row; multi-provider deployments stay sane about which row is active per workspace. **Owner-pool, not workspace-pool:** webhooks arrive pre-auth, the dispatcher resolves the workspace from the payload, workspace isolation is enforced per-handler on the read side.
4. **Provider-neutral `Event` + enum of `EventKind`.** The adapter's `VerifyAndParse` maps native event names (`checkout.session.completed`, `email.bounced`, …) onto one of our enum values; events we don't care about return `EventIgnore` with the event id still populated so the dispatcher can idempotently record them. The dispatcher downstream only reads neutral fields; vendor-specific fields never leak above the adapter.
5. **Auto-select the adapter at boot by which credentials are set.** `configureBillingProvider(cfg)` / `pickEmailSender(cfg)` returns `(provider, catalog, err)`; nil provider = feature disabled; invalid config = log and continue with the feature disabled rather than crashing boot. The provider's `Name()` method emits the discriminator used for stored rows and route params.

## Webhook endpoint — the single idempotent shape

One shared route shape: `POST /api/v1/webhooks/<domain>/{provider}`. The handler stays provider-neutral; everything vendor-specific lives in the adapter.

```
1. Resolve adapter. s.<domain> == nil OR adapter.Name() != {provider} → 404.
2. io.LimitReader body to 1<<20 (vendor payloads are small). Read error → 400.
3. adapter.VerifyAndParse(r, body) →
     ErrUnverified → 401
     ErrBadPayload → 400
     ok           → neutral Event + raw payload bytes
4. Insert into <domain>_events (provider, provider_event_id, event_type, payload)
   ON CONFLICT DO NOTHING. tag.RowsAffected() == 0 ⇒ replay, return 200 {"replayed":true}.
5. Dispatch the event. On error, record error on the row but STILL 200 (so the
   vendor stops retrying — unprocessed events surface via `WHERE processed_at IS NULL`).
6. On persistence failure BEFORE dispatch (step 4 raised a DB error), return 500 —
   let the vendor retry so we never lose the event.
```

Store the raw payload as `jsonb` via `$1::jsonb`; wrap non-JSON bodies in `{"invalid_json":true}` so the row never fails to land. Any ledger grants driven by the event carry the `provider_event_id` on the lot (`UNIQUE` partial index where NOT NULL) so a replay cannot double-grant.

## Scope-lock before writing any code

Integration PRDs are usually under-specified on exact numbers (plan prices, credit grants, SKU shape, expiry rules, retry policy). Fire ONE `clarify` call with the vendor's docs/defaults as the recommended option and resolve EVERY blocking decision in one round — never let "what price does the yearly discount round to?" surface three turns into the work. Common blocking decisions for a payments integration:

- Feature flag ON by default or opt-in per deploy?
- Free-tier grant policy (daily refill vs signup bonus only vs none).
- Plan tiers + exact monthly/yearly prices (including rounding of the yearly discount).
- Monthly credit grants per plan and their expiry (period-end vs never).
- One-time pack SKUs: credits, price, expiry.
- Vendor account exists? (If not, code can proceed; keys land at end.)
- Scope of the first PR vs follow-ups.

For email bounces or similar passive integrations the blocking set is smaller — but still ask ONE round rather than guessing.

## Multi-PR delivery under this pattern

When the user says "ship this across N PRs and merge between", structure the first PR as scaffolding-only: contracts package, adapter with signature verification only, webhook endpoint with a dispatcher that is a logger, DB schema, catalog read endpoint. **Checkout/portal/live-call methods on the adapter return `errors.New("not implemented in PR1")` rather than panicking or returning nil** — a wire-up mistake must surface loudly, not silently 500. PR2 wires the real dispatcher + checkout; PR3 wires one-time purchases + invoice download. Each PR builds + tests clean on its own; nothing live is dispatched until the real handlers exist.

## Pitfalls

- **Vendor payload fields are optional, not required.** Decode into tolerant structs: a missing field is zero-valued, not a parse error. A vendor schema addition (new field on the subscription object) must never break the webhook — pin only the fields we actually read.
- **Signature verification must enforce a timestamp skew bound.** 5-minute symmetric window is standard; without it a captured payload replays indefinitely. The skew check happens BEFORE the HMAC compare so a stale signature can't eat CPU on long bodies.
- **Never dedupe by `(workspace_id, event_id)` — dedupe by `(provider, event_id)`.** The vendor's event id is globally unique within that vendor; adding workspace to the key lets a cross-workspace replay slip through.
- **UI never names the vendor.** Marketing copy, settings pages, and buttons say "Upgrade" / "Manage billing" / "Buy credits", not "Pay with Stripe". The non-technical-user rule stands: the provider is an implementation detail. The one exception is the operator-facing audit log, which is allowed to say `provider=stripe` because only ops reads it.
- **Do not pre-provision Stripe/Paddle/etc. test keys in `.env.example`.** Blank env values must make the feature degrade gracefully (catalog returns `available:false`, webhook returns 404, boot logs a disable line). A fresh clone that hard-fails on missing third-party creds is a boot regression.
- **go.work must list BOTH the parent and the subpackage directories.** `./services/<domain>` and `./services/<domain>/<vendor>` are separate modules; omitting one gives a confusing `does not contain modules listed in go.work` error on first build.
- **Catalog numbers (prices, credit grants, SKU sizes, signup bonus) are canonical in Go, hand-mirrored into Next.js copy — edit both in the same commit.** `services/billing/catalog.go` plus `auth.SignupBonusCredits` are the source of truth; `apps/web/app/(marketing)/pricing/page.tsx` and `apps/web/app/(app)/settings/plan/page.tsx` repeat the numbers in human copy because Next cannot import Go constants. A bump to a plan's credits/month or to the signup bonus with no accompanying web edit silently ships a page that lies about the product. Workflow on every bump: grep `apps/web` for the OLD numeric value AND the plan/pack display name, patch each hit, and keep the plan doc's "Decisions locked" row in step. Also strike any `GAP(<name>)` comments in the surrounding `/pricing` or `/settings` copy that cover the thing you just resolved — stale GAP markers compound into "what else is wrong on this page" doubt.
- **The first-vendor instinct is wrong — write the root package contracts BEFORE the adapter.** The temptation on PR1 is to write a vendor-shaped catalog/client first because that is the thing you have docs for, then "abstract later." Later costs: the first adapter's naming leaks into the schema's `provider_customer_id` columns, the webhook route needs renaming off `/webhooks/stripe` to `/webhooks/billing/{provider}`, and the catalog's `StripeMonthlyPriceID` field has to be renamed `MonthlyPriceID` everywhere. Order of writes: (1) `services/<domain>/catalog.go` with vendor-neutral `MonthlyPriceID`/`PriceID` field names, (2) `services/<domain>/provider.go` with the Provider interface + neutral Event/EventKind, (3) `services/<domain>/<vendor>/` adapter that *implements* those interfaces. If the first file you open touches a vendor SDK or a vendor-specific JSON field name, stop and back up one step.
