# Auth, session, profile & account surfaces

Covers sign-in (OTP + OAuth), the session cookie, `/auth/*`, the account dropdown, and everything under `apps/web/app/(app)/settings/`. These surfaces share a property that makes them unusually bug-prone: **they look finished when they are inert.** A sign-in form that posts to a 404 still advances to "check your email"; a dropdown with no handlers still opens and highlights; a settings page with a disabled Save still renders every field. Visual review passes on all three. Only exercising the real request proves anything.

## Get a real session cookie for local verification

Dev OTP codes are printed to the API log rather than emailed, so the whole flow is curl-able. Do this FIRST when working on any session-scoped endpoint — half the bugs in this area are only visible with and without a cookie side by side.

```bash
rm -f /tmp/c.txt
curl -s -o /dev/null -X POST http://localhost:4000/auth/otp/request \
  -H 'Content-Type: application/json' -d '{"email":"rebel@example.com"}'

# the code is structured-logged, not emailed
CODE=$(grep '"msg":"otp issued"' /tmp/os-logs/api.log | tail -1 \
  | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["code"])')

curl -s -c /tmp/c.txt -X POST http://localhost:4000/auth/otp/verify \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"rebel@example.com\",\"code\":\"$CODE\"}"

# then every session-scoped call reuses the jar
curl -s -b /tmp/c.txt http://localhost:4000/auth/session
```

Codes are single-use and short-lived — re-run the request step for each new session rather than reusing a captured code. Always `rm -f` the jar first; a stale cookie from a previous API boot makes a broken auth path look working.

**Run every session-scoped endpoint twice: once with `-b /tmp/c.txt` and once without.** The unauthenticated call must 401. That second call is the one that catches placeholder-identity fallbacks, and it is the one everyone skips.

## Profile fields: check the column still exists

The profile editor writes `display_name`. A session/profile query selecting `u.name` compiles, runs, and returns an empty string forever, because that column was dropped by a later migration while the query kept referencing it through a `COALESCE` that masked the absence. The symptom is cosmetic and easy to dismiss — the top bar shows an avatar initial but no name — so it survives for a long time.

When a user-entered value does not appear where it should, diff the three places it travels before touching UI code: the column the editor WRITES, the column the read query SELECTS, and the JSON field the frontend reads. A mismatch at any hop produces a silent empty value, never an error. Confirm the column list with `\d platform.users` rather than reading the migration that created the table.

After a profile save, the server-rendered shell (top bar, avatar, dropdown header) holds the OLD values until the route cache is invalidated — call `router.refresh()` after a successful save, or the user edits their name, sees "Saved", and still sees the stale name one component away.

## OAuth: probe, don't assume; and carry `next` through the round trip

- **The provider button renders only when the API says the provider is configured.** Unconfigured OAuth returns `501`; a hardcoded button is a dead end. Serve a capability probe (`GET /auth/providers` → `{"email":true,"google":false}`) and gate the button on it.
- **The post-auth redirect target must be a route that exists.** An OAuth callback redirecting to a hardcoded destination drifts the moment the app's routes are reorganised, and nothing fails loudly — the user lands on a 404 after a successful sign-in, which reads as "login is broken". Centralise the destination in one helper rather than inlining an env read at the callback, and verify the target has a `page.tsx`.
- **`?next=` must survive the whole round trip.** The deep link the user was bounced from has to ride through the OAuth state parameter (or the state cookie) and come back out at the callback, because the redirect originates server-side where no client state exists. Validate it on the way out: accept only same-origin paths beginning with a single `/`, rejecting `//host` and absolute URLs, or the parameter is an open-redirect.
- Same rule for the OTP path: `requireSession` should redirect to `/signin?next=<current path>` and the form should honour it on success. Bouncing everyone to the root after sign-in silently discards the thing they were trying to reach.

## Settings pages: a disabled Save is a shipped placeholder

Settings surfaces are where "coming soon" accumulates. A page with real-looking fields, a permanently disabled Save, and a list synthesised client-side from one known value (e.g. a members table built from the current user's email) is indistinguishable from a working page in a screenshot. Treat any of these as unfinished:

- a Save/submit control that is `disabled` with no state that can enable it
- a success flag set locally without a request (`setSaved(true)` with no `await`)
- a list rendered from a literal array where an endpoint should supply it

Each needs a real endpoint behind it. For preferences, the clean shape is one row per `(user, key)` with absent-row = product default — new users work with zero rows and no backfill migration is needed. Verify persistence across requests, not within one: write, then re-read in a SEPARATE curl, since an optimistic local state will echo the value back within the same page session whether or not anything was stored.

## Dead affordances: a menu item with neither `href` nor `onSelect`

A dropdown built from a factory of `{id, label, icon}` records renders perfectly, opens, highlights on hover, and closes on click — while doing nothing. Radix `DropdownMenu.Item` requires no handler, so the omission is not a type error and not a visual defect. The highest-severity instance is **Sign out**, which reads as working (the menu closes) while the session stays live.

Audit the menu's data source, not its rendering: every item must resolve to a destination or an action.

```bash
rg -n 'id:\s*"' apps/web/components/overlays/account-menu.tsx       # items declared
rg -n 'href:|onSelect:' apps/web/components/overlays/account-menu.tsx  # items wired
```

A count mismatch is the bug. Prefer `href` + `asChild` over an `onSelect` that pushes — rendering a real `<a>` keeps middle-click, cmd-click and "open in new tab" working, which a programmatic push silently breaks. Reserve `onSelect` for genuine actions (sign out, open a dialog). After sign-out, hard-navigate rather than `router.push` so the server-rendered shell cannot keep showing the signed-in user from cache.

The same shape recurs in command palettes, context menus, and empty-state CTA buttons — anywhere items come from a data array rather than literal JSX.

## Fetch wrappers that swallow non-2xx

A submit handler shaped `try { await fetch(...) } finally { setStep(next) }` advances the UI whether the request succeeded or not. On a sign-in form this means a 404 from a wrong path still shows "Check your email", and the user waits for a code that was never issued — the single most misleading failure in this area, because the only evidence is a code that never arrives. Check `res.ok`, surface the message, and advance only on success. Audit every `fetch` in a flow for a status check before trusting any "it works" report about that flow.

## Browser-driving notes for these flows

Radix menus do not open from a synthetic `element.click()` — they listen for real pointer events. Use `click_at_xy` on the trigger's coordinates. Likewise, assigning `input.value` directly does not fire React's `onChange`; use the native setter and dispatch an `input` event:

```js
const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
setter.call(el, char);
el.dispatchEvent(new Event('input', { bubbles: true }));
```

Restarting the Next dev server drops the browser's session cookie — re-run sign-in before concluding a page regressed. A tab can also go stale (`location.href` reads `about:blank`); call `ensure_real_tab()` and re-navigate rather than reading it as a page crash.

## Auth gap-review: map before coding

When asked to "finish auth" or "discuss the gaps", resist starting a plan from the PRD. Inventory first across BOTH axes — authn surface and authz pipe — because people conflate them and ship a working sign-in on top of an authz layer that ignores workspace roles.

**Cross-check the gap docs against `git log` before quoting them.** `docs/PRODUCTION-READINESS.md` and `docs/plans/*auth*.md` are written at a point in time; by the time someone asks "what's left", chunks have shipped and the doc still lists them as TODO (OTP rate limits, signup flow, session sweeper, dev-login hardening, invitations, role management, scope mapping, session management all landed while the doc kept the pre-merge wording). Run this before answering:

```bash
git log --oneline --all | rg -iE 'auth|signup|invit|rbac|session|rls' | head -40
ls docs/plans/ | rg -i auth    # plans in flight vs. already merged commits above
```

Map each `PRODUCTION-READINESS.md` auth item to a commit or a still-open plan; demote the shipped ones out of the "left to do" list in your reply, and separately flag the doc itself as stale (that is one of the real deliverables of a "tidy up docs/gaps" ask, not a side note).

**Parallel docs that drift when auth PRs land** (verify presence, name any that are missing as part of the gap):

- `docs/openapi/openstudio.yaml` — the OpenAPI spec covers `/api/v1` + `/internal` but not `/auth/*`. Every PR that adds a `/auth/*` endpoint (signup/start, signup/verify, otp/request, invitations/accept, session/list, etc.) widens this gap silently.
- `docs/adr/` — there is no ADR for the auth model (magic-link + Google OAuth, no password, session-cookie vs API-key split, scope list, RLS enforcement plan). The next free number is `ls docs/adr | tail -1` + 1.
- `docs/runbooks/` — only `observability.md` exists; no auth runbook for secret rotation, revoking a session, reading `platform.auth_audit`, responding to credential-stuffing.
- `docs/auth.md` — no single reference for cookie flags, endpoint list, scope matrix, rate limits, dev-login env vars; the information is scattered across the two plan files and `PRODUCTION-READINESS.md §1`.

One-pass code sweep (≈6 greps, no code edits):

```bash
# authn surface
rg -n 'r\.(Post|Get|Delete)\("/auth' apps/api/main.go           # endpoints wired
rg -n 'handle(OTP|Google|Signout|Session|Auth|DevLogin)' apps/api/auth_handlers.go
ls apps/web/app | rg -i 'sign|auth|login'                       # UI pages present

# authz pipe
rg -n 'HasScope|requireScope|Scope[A-Z]' services/auth/*.go apps/api/*.go
rg -n 'Principal\{|Scopes:\s*\[\]string' apps/api/auth_handlers.go  # how sessions get scopes
rg -n 'workspace_members|GetWorkspaceMemberRole' services/db/store/*.go apps/api/*.go

# shape
ls services/db/migrations | rg -i 'session|identit|member|invite|user'
```

Report back as three buckets — Shipped, Gaps, Bugs — and let the user pick scope before writing a line of code. The buckets that bite hardest and are easiest to miss:

- **Static scope mapping on session principals.** `sessionMiddleware` typically hardcodes a scope set (e.g. `[projects:write, catalog:read]`); workspace `role` from `platform.workspace_members` exists in the DB but never reaches `Principal.Scopes`. Admin-scoped routes (`admin:catalog:write`) are then effectively API-key-only, and workspace admins cannot do admin things through the dashboard. Check this before claiming authz is done; the fix is a role→scope mapping inside `sessionMiddleware` after `LookupSession`.
- **OTP rate limiting lives on `/api/v1`, not `/auth`.** The chi ratelimiter group wraps the API router, not the auth router, so `/auth/otp/request` and `/auth/otp/verify` are uncapped. An unauthenticated email-spam and six-digit brute-force surface. Treat an auth review that does not name a limit on both endpoints as incomplete.
- **Dev shortcuts gated on `APP_ENV != "production"` alone.** One misset env in deploy = account takeover. Belt-and-braces with a build tag or explicit flag; name it as a gap even if the current deploy is safe.
- **No distinct signup flow.** `FindOrCreateUserByEmail` silently creates a user + personal workspace on first OTP verify. The OTP path passes `name=""`, so `display_name` is only ever populated by Google users; ToS/privacy consent is never captured. A product that calls itself multi-user needs an explicit signup step at least long enough to capture a name — list this as a gap, not a stylistic nit.
- **Invitations / role management absent.** `workspace_members` has roles, but no endpoint invites, accepts, removes, or promotes. The settings page is a disabled form. Multi-user authz without this is theatre.

## Ledger grants on login are not idempotent despite the comment

`mintSessionForEmail` fires `ledger.Grant(..., LotAdmin, 5000, ...)` after every successful OTP/Google/dev-login verify, with a comment claiming the grant is idempotent. It is not: `Grant` appends a lot row rather than upserting, so every sign-in credits the workspace another 5000. The free-credits-on-login bug reads as "generous dev seed" until a prod deploy inherits the same code path.

Rule: when a comment claims a mutation is idempotent, read the write path. For ledger specifically, confirm the call site branches on `workspace_credits == 0` or on a `created_at IS NULL` first-seen signal before granting; a bare `Grant` on a hot auth path is a dupe-on-every-call bug. Same shape appears any time a bootstrap grant lives inside a mint/login/upsert helper rather than in the user-create branch of `FindOrCreateUserByEmail`.

## A security-invariant gate must hard-fail, not WARN-and-continue

A check that MUST succeed for the following write to be legal (one-time grants, idempotency sentinels, uniqueness probes, dedup lookups) cannot be downgraded to `slog.Warn(...)` on error. The pattern

```go
granted, err := store.WasSignupBonusGranted(ctx, email)
if err != nil {
    slog.Warn("signup bonus check failed", "err", err)
    return // or: granted = false
}
```

turns the invariant into a vacuous truth: in production the check fails (missing GRANT, closed pool, timeout), the WARN goes to a log nobody reads, the follow-up write is also skipped, and the symptom only surfaces when a user reports it. For gates like this, return the error and let the handler 500 — a loud failure in auth beats a silent one. Keep WARN-and-continue for TELEMETRY (counters, breadcrumbs, best-effort audit) where skipping is genuinely safe.

## Delete-and-re-register must not re-grant one-time bonuses

Sign-up bonuses, free-trial seeds, and first-user perks keyed by `user_id` reset the moment a user is deleted and re-registers with the same email, because the gating row disappears with the FK cascade. Rule: one-time grants are keyed by the normalised email in a sentinel table with **no FK to `platform.users`** (`platform.signup_bonus_grants(email CITEXT PRIMARY KEY, workspace_id TEXT, lot_id TEXT, granted_at TIMESTAMPTZ)`). The gate checks the sentinel, not the user row, so delete-and-recreate still passes `WasGranted(email) == true` and the second sign-up gets zero credits. Verify this invariant with a live two-pass test — unit tests on the sentinel alone will not catch a path that forgot to check it.

## New-handler guards: match the project's lint tests, not the obvious shape

`apps/api` carries a test (`TestNoHandlerRelliesOnBareNilPrincipalCheck`) that greps handler bodies for `if p == nil` and fails the whole suite when it finds one. `principalFrom(ctx)` returns a zero-value `*auth.Principal` (never nil) when the context has no principal, so the nil check is a true-looking guard that never fires. The correct guard is on identifying fields:

```go
p := principalFrom(r.Context())
if p.UserID == "" || p.WorkspaceID == "" {
    writeAuthError(w, errs.CodeForbidden, "forbidden")
    return
}
```

Before adding a new protected handler, `rg -n 'principalFrom\(' apps/api | head` to copy an existing in-tree pattern — the lint test is only one of several structural checks, and failing it blocks `go test ./...` on an unrelated-looking regression.

## Fire-and-forget vs. hard-fail: pick by whether the write is a GATE

Same handler can need both patterns in different lines:

- **Hard-fail (return the error, let the handler 500):** anything that gates the next write — one-time grant checks, idempotency sentinels, uniqueness probes, scope lookups. The gate rule above still applies.
- **Fire-and-forget (goroutine + 2s timeout, errors logged, user path unblocked):** telemetry writes that cannot gate anything — audit-log inserts, `last_seen_at` bumps, best-effort breadcrumbs. The user's request must not wait on them, because a slow Postgres then 500s surfaces the user never caused.

Shape:

```go
go func(ev auth.AuditEvent) {
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    if err := store.InsertAuditEvent(ctx, ev); err != nil {
        slog.Warn("audit insert failed", "err", err, "event", ev.Event)
    }
}(ev)
```

Never reuse the request's `r.Context()` here — it is cancelled the instant the response is flushed, and the goroutine then races the write against the cancel.

## Throttling a middleware-driven write without a background job

Middleware that wants to touch a row on every authed request (`sessions.last_seen_at`, `api_keys.last_used_at`, hit counters) will write-amplify a database if left unguarded. The right primitive is a per-process in-memory window with an eviction cap, not a background sweeper or a Redis dep:

```go
type touchThrottle struct {
    mu   sync.Mutex
    last map[string]time.Time
}

func (t *touchThrottle) shouldTouch(key string, window time.Duration) bool {
    t.mu.Lock()
    defer t.mu.Unlock()
    now := time.Now()
    if prev, ok := t.last[key]; ok && now.Sub(prev) < window {
        return false
    }
    if len(t.last) > 10_000 { // half-evict rather than scan on every call
        for k := range t.last { delete(t.last, k); if len(t.last) <= 5_000 { break } }
    }
    t.last[key] = now
    return true
}
```

5-minute window per session is the right default: on a process restart the first authed hit per session takes a single write and then quiets back down. Verify in production with a `psql -c "SELECT EXTRACT(EPOCH FROM (last_seen_at - created_at)) FROM platform.sessions ..."` — gaps > 1s mean the throttle is firing, gaps = 0 across repeated hits mean it is holding.

## `platform.sessions.workspace_id` is NOT NULL — tests must seed a real workspace

Any Go test that calls `CreateSession(ctx, sid, uid, "", exp, ip, ua)` with an empty workspace fails with `23503 foreign_key_violation` from the `workspace_id → workspaces.id` constraint, not the obvious NULL check. Seed a workspace per session in setup (`FindOrCreateUserByEmailDetailed` returns one; so does an inlined `INSERT INTO platform.workspaces(id, name) VALUES (...) RETURNING id`). Session-management tests that pass empty-string placeholders look innocent and fail only when the DB is reachable, so they are the most common red run on a fresh clone.

## `apiFetch<T>` returns parsed JSON — do not wrap it in a `.ok` check

`apps/web/lib/api.ts` exports `apiFetch<T>(path, init?): Promise<T>`. It parses JSON internally and throws `OpenStudioApiError` (with `.status` + `.code` + `.message`) on any non-2xx. Treating the return as a `Response` compiles but all usage is wrong — you end up `.json()`-ing an already-parsed object and never surfacing error messages. Correct shape:

```ts
try {
  const data = await apiFetch<{ sessions: SessionRow[] }>("/internal/session/list");
  setSessions(data.sessions);
} catch (e) {
  if (e instanceof OpenStudioApiError && e.status === 403) { /* re-auth */ }
  else { setError(e instanceof Error ? e.message : "unknown"); }
}
```

When the first draft of a new settings page throws 10+ TS errors against `.ok` / `.json()` / `.status` in a chain, the diagnosis is almost always this mismatch — re-check the signature in `lib/api.ts` before `tsc`-chasing field by field.

## Server-rendered shell data for the account menu

The top-nav `AccountMenu` lives inside `AppShell` which is server-rendered by `app/(app)/layout.tsx`. Fetch extras (workspaces list, scopes) server-side with `serverFetch<T>(path)` — it forwards the session cookie from `cookies()` — and pass as props. Catch the fetch so a transient API outage degrades the dropdown to a single-workspace static row instead of 500-ing the whole app shell:

```ts
let workspaces: WorkspaceOption[] = [];
try {
  const extras = await serverFetch<{ workspaces: WorkspaceOption[] }>("/internal/session/extras");
  workspaces = extras.workspaces;
} catch { /* dropdown collapses to the known workspace name */ }
```

Workspace switch itself must be CLIENT-side (`fetch("/internal/workspace/switch", { method: "POST", ... })` then `window.location.assign("/home")`) so the session cookie rebinds in the browser before the next navigation. A server action that calls switch and then redirects loses the Set-Cookie because the shell was already rendered.

## One flow component, two intents — do not fork sign-in and sign-up

Marketing wants a `/signup` URL to link "Start free" buttons at. Resist adding a parallel `SignUpFlow` component; the OTP email-first flow is identical and the signup/signin pivot already lives inside the component (API's `otp/request` tells it whether the email is new). Add an `intent: "signin" | "signup"` prop that only switches the heading, sub-copy, and the cross-link direction, and mount it from `app/signup/page.tsx` with `intent="signup"`. Both pages share one source of truth for retry/resend/error states; a fork guarantees they drift.

The cross-link belongs at the bottom of the email step on both pages, carrying `?next=` across so deep-link bounces survive the page swap. Marketing hero form `action="/signup"` and "Start free" header button `href="/signup"` — the generic "Sign in" link stays on `/signin`.

**Alternate entry points for the same flow (OAuth redirect targets, deep-linked re-auth) pass an `initialStep` prop; do not clone the flow.** When the API's Google callback / step-up re-auth / password-reset path needs to drop the user mid-flow (e.g. on `/auth/2fa` with the TOTP step pre-selected), add a page at that route that mounts `SignInFlow initialStep="<step>"`. The prop takes precedence over the `?step=` query param so the browser URL stays clean, and the shared flow keeps all retry/resend/error states in one place. A fresh component per entry point drifts the moment one of the shared states gets a bug-fix.

## Dev-only UI shortcuts leak unless the server probe is also pruned

Removing a "dev shortcut: sign in as X" button from the UI only closes half the surface — the capability probe (`GET /auth/providers`) still returns `devLogin: true` in dev, and any future UI that reads that field will reintroduce the button. Decide which side owns the gate: if the server endpoint stays (test tooling may call it directly), prune the probe field so no UI can discover it; if the endpoint is removed, the probe field goes with it. Shipping the UI removal without touching the probe is the shape that eventually regresses.

## Splitting a large authz PR

An auth-track PR that includes invitations, role management, scope mapping, session management, audit log, workspace switcher, and API-key patching is ~1500–2000 LoC and gets rubber-stamped. Split by data-ownership boundary rather than by UI vs. backend:

- **slice 1 — membership & roles:** `invitations` table + handlers, role CRUD on `workspace_members`, scope mapping in `sessionMiddleware`, boards-authz cleanup. Everything that answers "who can be in this workspace and what can they do".
- **slice 2 — session metadata & audit:** `sessions.{last_seen_at,ip,user_agent}`, `platform.auth_audit`, session list / revoke / signout-everywhere, workspace switch endpoint, API-key PATCH. Everything that answers "what has this user been doing from where".
- **slice 3 — polish (optional):** TouchSession middleware wire-up, top-nav workspace switcher UI. Items the first two slices intentionally deferred.

Each slice ~700–900 LoC, independently reviewable, independently revertable. The deferred items from an earlier slice MUST be named in that slice's PR description so slice 3 is not a surprise.

## Keep a canonical taxonomy honest with a grep trip-wire

When a surface emits a closed set of strings (audit event kinds, scope names, error codes, provider ids) that MUST match a docs table and an OpenAPI enum, the drift between code and docs is silent — a renamed emission still compiles, still 200s, and the review-time symptom is just a missing row in the dashboard a week later. The cheapest guard is a Go test that owns the list AND greps package source for every entry:

```go
var expectedEventKinds = []string{ /* alphabetical, one per line */ }

func TestExpectedEventKindsIsSorted(t *testing.T) { /* trip-wire for order */ }

func TestAllExpectedKindsAreEmittedSomewhere(t *testing.T) {
    src := readPackageSource(t) // concat every non-test .go in the dir
    for _, want := range expectedEventKinds {
        if !strings.Contains(src, `"`+want+`"`) {
            t.Errorf("kind %q listed but no literal reference in apps/api", want)
        }
    }
}
```

Why a grep over the whole package rather than a per-handler assertion: emissions live in half a dozen files, some via helper functions (`eventKindFor(created)` returns `"user.created"` or `"session.login"`), and the test must survive refactors that move the emit site. The grep tolerates helper indirection as long as the literal string lives SOMEWHERE in the package. Point the OpenAPI enum (`AuditEvent.event` in `auth-schemas.yaml`) and the `docs/auth.md §7` table at the same list by name in the file comments — a human adding a kind now updates one list; the trip-wire fails any PR that forgets the other two.

**Layer a per-handler body-check on top when the package grows past ~15 kinds.** The package-grep catches silent deletes but not silent *moves* — a handler that used to emit `invitation.revoked` can lose its Emit call entirely and the test still passes because another file still mentions the kind. The second-layer test maps handler NAME → required kinds, extracts the brace-balanced function body (find `) <fnName>(`, advance to `{`, walk with a depth counter until it closes), and asserts every required kind string appears inside that specific body plus at least one literal `auth.Emit(`. This catches drift that the package-wide grep tolerates. Keep the map alphabetical by handler for cheap diff review, and encode the alternative-branches case (one handler that emits one of several kinds based on an internal pivot — e.g. 2FA challenge success emits `twofa.challenge_passed` OR `twofa.recovery_used`) as a list of ALL possible kinds; `strings.Contains` across the whole body passes for every branch simultaneously, which is correct for drift detection. Reject the obvious-looking alternative — driving every handler through httptest with a `capturingSink`: it duplicates DB/ledger/session fixtures that the per-feature tests already have, and the drift it protects against (handler added without an Emit) is a property of the SOURCE, not of runtime behaviour.

## Vendor-webhook namespace: `/api/v1/webhooks/{domain}/{provider}`

All inbound provider callbacks mount under one shape — `cinematic/higgsfield`, `social/zernio`, `email/resend`. When a new provider lands, the only change is one entry in the handler's dispatch map; the route surface is predictable from a glance at the OpenAPI spec. Earlier routes (`/api/v1/cinematic/webhooks`, `/api/v1/social/webhook`) were per-domain singletons that forced new vendors into either a different URL shape (confusing in logs) or an awkward path param on the old URL (breaks the vendor's already-registered URL). When the user signals "follow one consistent pattern", move the route AND remove the shim — do not leave aliases "for one release"; a deprecation shim lives longer than any plan says it will and the review-time symptom is a 200 on a dead URL that nobody notices.

## Adapter-pattern layout for a pluggable external service

`services/email/` is the shape to copy for any new vendor-backed surface (future: SMS, antivirus, geocoding, payment). Three directories, one Go module each:

- `services/<domain>/` — contracts only. `Sender` / `Parser` interfaces, shared `Message` / `Event` types, sentinel errors (`ErrUnverified` et al). Zero provider-specific code; a dependent importing just this gets no vendor SDK.
- `services/<domain>/<provider>/` — one sub-module per provider. Imports contracts via `replace github.com/agentclip/openstudio/services/<domain> => ../`. Lives on its own `go.mod` so the dependency graph stays acyclic and `go test ./...` on the parent does not pull every vendor SDK.
- `apps/api/<domain>.go` — picker + mailer-style shim. `pick<Thing>(cfg)` resolves the explicit env var first (`EMAIL_PROVIDER`), falls back to auto-select by API-key presence, else returns the dev adapter. `(*state).send<Thing>` is the fire-and-forget wrapper call sites use. Mid-course correction cost: if the first draft wired the provider directly in `apps/api/<domain>.go` and the user later asks for provider-agnostic, the rebuild is small *because* the handler never touched provider types — the adapter boundary is what makes the rewrite cheap, so put it in on the first pass even for one provider. Each additional provider = one sub-package + one line in the picker.

## 2xx with a pivot discriminator in the body: login that owes a second step

When `/auth/otp/verify` (or any identity-confirmation handler) can succeed outright OR require a follow-up challenge (2FA, pending-approval, step-up), the handler returns 2xx in both cases and the body carries the discriminator: `{ok:true}` means session cookie is set, done; `{ok:true, twoFA:true}` means `os_pending` was set instead and the client must POST to `/auth/2fa/verify` next. The frontend MUST parse the response body on 2xx before deciding what to do — a bare `if (res.ok) window.location.assign(next)` navigates away from the challenge screen before the user ever sees it. The rejected alternative shapes and why:

- **Return a non-2xx with a 'challenge required' code.** Breaks every generic fetch wrapper that treats non-2xx as an error toast; `apiFetch`'s `OpenStudioApiError` path would surface "challenge required" as a red banner. Wrong.
- **Set a response header and ignore the body on 2xx.** Browsers lowercase and reorder headers; a header-driven pivot that works in curl silently fails cross-fetch when a middleware strips an unrecognised `X-...` header. The body is the only robust channel.
- **Rely on the `os_pending` cookie's presence in the next request.** Cookies are side-effects observed by subsequent requests, not return values of this one. The client has to decide what to render NOW from the response in hand.

Shape the frontend reads: parse the body on 2xx, branch on the pivot field, and only navigate when the field is absent. Comment the two success shapes at the parse site so a future reader does not strip the body-read as dead code.

## A new user-facing feature with a login-time half needs the login screen too

"Just the settings UI" is a trap for anything that both mutates state (enrollment) AND gates a future login (challenge). Settings-only ships the enrollment flow, the DB rows persist, the next sign-in attempt sets `os_pending` — and the user has no page to enter the code on. The dashboard renders a success toast; the sign-in form navigates to `/home` on 2xx; the pending cookie expires in ten minutes and the user cannot complete authentication. Review-time symptom: nothing. The gap is only visible to a user who turns the feature on and then tries to sign in from a new tab.

Before agreeing to a settings-only scope on a feature like this, map the FULL lifecycle in one line each: enable path, disable path, every entry point that can trigger the challenge (OTP sign-in, Google callback, step-up re-auth, long-lived session re-verification), the challenge screen itself, and the recovery path if the challenge fails. If any leg is "deferred", say so OUT LOUD when confirming scope — "shipping the settings UI; users who enable this cannot currently sign in with it from a fresh browser until the challenge screen lands" — so the user chooses to defer with eyes open. The same shape governs API-key UIs (settings mint without a developer docs page explaining how to send the header), billing (plan picker without a payment-method prompt), and any feature where configuration and consumption live on different surfaces.

## Deferred lifecycle emission when a login is gated

Any time an identity-confirmed step is followed by a second challenge before a session materialises (2FA, step-up re-auth, pending-approval), the `session.login` / `user.created` audit event fires FROM the challenge success path, not from the common session-minting helper. The helper that would normally emit must return a sentinel (`errTwoFARequired`) so callers can render the "enter your code" response without a session cookie. Reasoning: the audit log claims a login *happened*, so emitting from the helper on the pre-challenge call writes a lie — one event per attempt even when the challenge then rejects. The downstream analytics / rate-limiter / "you have a new sign-in from X" email all read the audit log; keep the emission at the point the session is actually live. Fresh signups skip the gate (new users cannot have 2FA enrolled yet), so `created==true` short-circuits past the pending-session write.

## Disable / rotate / downgrade of a sensitive feature needs FRESH proof

A session cookie is proof-of-identity, not proof-of-presence. Any endpoint that can disable 2FA, rotate recovery codes, change the recovery email, downgrade an API key's scopes to superuser, or remove the last owner from a workspace must require a second factor on the request itself (TOTP code, recovery code, password, OAuth re-auth). Rule: cookie alone cannot undo a protection the cookie bypassed to enable. The same applies in reverse — ENROLLING 2FA from a cookie is fine; DISABLING it needs the TOTP in the body. On success, emit the audit event with `meta.proof: totp|recovery|password` so a dashboard entry can distinguish "user disabled with fresh TOTP" from "operator teardown" (see `docs/runbooks/auth.md §12`).

## `platform.auth_audit` column names

- Timestamp column is `occurred_at`, NOT `created_at`. Live-cleanup queries written from muscle memory (`DELETE FROM ... WHERE created_at > NOW() - INTERVAL '10 minutes'`) 42703 against the audit table. The ONE-TIME grant sentinel (`platform.signup_bonus_grants`) uses `granted_at`. Platform timestamps are not standardised — run `\d platform.<table>` once before writing a cleanup query.
- `actor_user_id` is the caller; `target_user_id` is the subject when distinct (role change, member removal, ownership transfer). Both are TEXT, both nullable. The emission site in `services/auth/events.go` must populate `TargetUserID` explicitly for actor≠subject events — a hardcoded `TargetUserID: ""` in the audit sink defeats the whole second-field design.

## OpenAPI 3.1 split-file conventions in `docs/openapi/`

- Route defs for a bounded surface live in a sibling file (`auth.yaml`) and are composed into `openstudio.yaml` via one `$ref` per path. The ref uses JSON-pointer-encoded path keys: `/auth/providers` becomes `./auth.yaml#/paths/~1auth~1providers`. Each `/` in the path is `~1`.
- Shared `components/responses/*` and `components/schemas/*` stay in the main spec; sibling files reach them with cross-file refs: `$ref: './openstudio.yaml#/components/responses/BadRequest'`. Local-only shapes live in a sibling schemas file (`auth-schemas.yaml`) because `components:` has no first-class split.
- `security:` references the main spec's `securitySchemes:` by name only (it is NOT a `$ref`); the sibling file is only valid when composed and the lint tool knows this.
- `redocly bundle docs/openapi/openstudio.yaml -o /tmp/bundled.yaml` is the composition test; `redocly lint` reports pre-existing errors on unrelated schemas so the right metric for a new PR is "zero NEW errors from my files" (`grep ... auth\.yaml | wc -l` on the error list), not "zero errors total".
- **YAML flow mapping gotcha**: `{ description: Bad request (target not a member, etc.) }` splits on the comma mid-paren and parses as two keys. Values with commas, parens, colons, or hashes MUST be quoted: `{ description: 'Bad request (...)' }`. The lint error reads `operation-summary` and is misleading; the fix is quoting, not adding a `summary:`.
- **Deprecation-shim docs are a false signal.** Leaving a path entry marked `deprecated: true` with a "use the real route" description preserves a URL in the generated client that the API has already removed. When a route is gone, delete the OpenAPI entry; do not describe a 404 as if it were an endpoint.

## Rendering TOTP / shared-secret UI client-side only

When a settings screen must display a shared secret (TOTP enrollment QR, newly-minted API key, recovery codes, OAuth client secrets), the visualisation layer runs **in the user's tab**, not in a third-party service. The failure shape to avoid is `<img src="https://api.qrserver.com/v1/create-qr-code/?data=${otpauthUri}">` — the TOTP secret then transits a stranger's HTTP log. Use a client-side renderer (`qrcode` npm package → `QRCode.toDataURL(uri, { errorCorrectionLevel: 'M', margin: 1, width: 240 })`) and set the resulting data URL as `<img src>`. The secret never leaves the tab. Same rule for any screen that embeds a secret in a scannable code, pastable deep link, or signed URL.

Show the manual-entry secret next to the QR so the user can type it when the camera is unusable, and label the issuer + account under both: those three strings together are what the authenticator app will store, so a user hunting for "the one from OpenStudio" needs them visible on the enrol screen.

## One-time-shown secrets: UX shape

Recovery codes, API-key secrets, download-once backup bundles — anything the server will never return again — all take the same shape in the UI:

- Render the full set at once in a grid of `select-all` cells so a user can triple-click or drag-select without JS.
- Give three actions: **Copy all** (writes the newline-joined set to the clipboard), **Download .txt** (Blob + object URL + `<a download>`), and **I've saved them** (dismisses to the resting state). The dismiss button is primary; the other two are secondary.
- Prime the user BEFORE the reveal, not after: a one-sentence header saying "these won't be shown again" above the grid, not a footnote beneath it, so the eyeline sees the warning before the codes.
- Keep the "low codes remaining" nudge on the resting status card at `<=2` and point the user at disable + re-enable rather than a dedicated regenerate endpoint — one path to a fresh set, destructively replacing the old one, is simpler than two.
- Never store the shown codes in `localStorage`, `sessionStorage`, or a React state that survives a route change. Phase state (`idle | codes | …`) lives only in the component and is dropped the moment the user dismisses.

## Checklist before calling an auth/account change done

1. Every frontend path curled against the running API — no 404/405 (see the sweep in SKILL.md).
2. Every session-scoped endpoint 401s with no cookie, 200s with one.
3. Every dropdown/menu entry has a destination, and every `href` has a `page.tsx`.
4. Sign-out clears the cookie AND the UI no longer shows the user (full navigation, not a client push).
5. Each settings page: write via curl, re-read in a separate request, value persisted.
6. Capability-gated buttons hidden when the capability probe reports false.
7. `go build ./apps/api` and `npx tsc --noEmit` in `apps/web` both clean.

Steps 1–6 are the ones a build and a test suite cannot do for you.

## Separating your bugs from the repo's

This area touches enough surfaces that a pre-existing failure will surface mid-task and read as collateral damage from your change. Before reporting a build or test failure as yours — or "fixing" it — reproduce it at HEAD in a clean worktree:

```bash
git worktree add /tmp/os-baseline HEAD
ln -s "$PWD/apps/web/node_modules" /tmp/os-baseline/apps/web/node_modules
ln -s "$PWD/node_modules" /tmp/os-baseline/node_modules
cd /tmp/os-baseline/apps/web && npx next build
```

Prefer this over `git stash`: stashing your own work to test a baseline risks the restore, while a worktree leaves the working tree untouched. Clean up with `rm -f` on the symlinks, then `git worktree remove /tmp/os-baseline --force`. Name pre-existing failures explicitly in the commit message so the next person does not re-diagnose them.

## Tests for bugs that live in config

When the defect is in `next.config.js`, a migration's grants, or any other non-Go artifact, the regression test still belongs in `apps/api` — it is the package with a test runner already wired up. Read the file from disk and assert the invariant. **Then prove the test fails against the broken state**: reintroduce the bug, run the test, confirm red, restore. A config guard never seen failing is indistinguishable from one whose matcher silently matches nothing.

When an existing test asserts the OLD behaviour you just fixed (e.g. one pinning the placeholder-identity 200), rewrite it to assert the new contract plus a guard against the regression — do not delete it, and do not relax the handler to keep it green.
