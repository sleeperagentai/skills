# Observability stack (ADR 0012)

Self-hosted OTel on this VM: Grafana + Loki + Tempo + Prometheus + Pyroscope + OTel Collector, booted via `scripts/dev-native/up.sh --obs`. Plus a dedicated `openstudio_obs` Postgres database for the external-call audit log with raw unmasked bodies. No Docker (per the top-level invariant); binaries live under `~/.openstudio/obs/bin/`.

## Binary sourcing on darwin arm64

- `grafana`, `prometheus` — Homebrew (`brew install grafana prometheus`).
- `tempo`, `loki`, `pyroscope`, `otelcol-contrib` — GitHub release tarballs into `~/.openstudio/obs/bin/`. **Tempo 2.x has no darwin arm64 build; use 3.1.0+ and update the config shape (next section).** Loki/Pyroscope/otelcol-contrib latest work fine.

## Config shape pitfalls — load-bearing, learned the hard way

- **Tempo 3.x monolithic (`target: all`) rejects 2.x-style blocks.** `ingester`, `compactor` do not exist. Use the authoritative single-binary example: `distributor.receivers.otlp`, `metrics_generator`, `storage.trace.{backend,wal,local}`, `overrides.defaults.metrics_generator`. Grab the live reference with `curl -sL https://raw.githubusercontent.com/grafana/tempo/vX.Y.Z/example/docker-compose/single-binary/tempo.yaml` — never pattern-match older community posts.
- **Tempo 3.x hardcodes `/var/tempo` for live-store/scheduler paths — they are CLI flags, not config keys.** Launching with just `-config.file` dies on `permission denied` writing `/var/tempo/...`. Pass all four on the command line:
  - `-live-store.wal.path="$OBS_HOME/tempo/live-store-wal"`
  - `-live-store.shutdown_marker_dir="$OBS_HOME/tempo/shutdown-marker"`
  - `-block-builder.wal.path="$OBS_HOME/tempo/block-builder-wal"`
  - `-backend-schedulerbackend-scheduler.local-work-path="$OBS_HOME/tempo/scheduler"` (the doubled prefix is real, confirmed via `tempo --help`).
- **Pyroscope v2 defaults to `v1-v2-dual` architecture and needs a metastore on :9095.** Single-binary local use requires `-architecture.storage=v1 -write-path=ingester` on the CLI, and the config must NOT contain `blocks_retention_period` under `compactor` or a top-level `usage_stats` block (both rejected by main.mainFlags).
- **otelcol-contrib removed the `loki` exporter.** Export logs to Loki's native OTLP endpoint instead:
  ```yaml
  exporters:
    otlphttp/loki:
      endpoint: http://localhost:3100/otlp
      tls: { insecure: true }
  ```
- **OTel Collector env substitution has no implicit default.** `${env:OPENSTUDIO_ENV}` fails the config at startup when the var is empty; use `${env:OPENSTUDIO_ENV:-development}`.
- **Prometheus retention is a CLI flag, not a config key.** `storage.tsdb.retention.time: 15d` in prometheus.yaml is a startup error. Pass `--storage.tsdb.retention.time=15d --web.enable-remote-write-receiver` on the command line; the latter is required to accept the Collector's `prometheusremotewrite`.
- **Grafana must bind `:3030` on this host — `:3000` is owned by `next dev`.** Set it in `grafana.ini` AND in `up.sh`'s launch args; a stale default Grafana install will steal 3000 silently and the web app's dev server will fall back to 3001 without complaining.

## Restart hygiene

- **`down.sh` kills by pidfile; Tempo children can hold `:3200` past that.** On restart you'll see `bind: address already in use` in `state/logs/tempo.log`. Recover with `pkill -f "openstudio/obs/bin/tempo"` then `rm -f state/pids/tempo.pid` and re-up. Same pattern applies to any obs binary that spawns workers.
- **Health probe sweep (10–20 s after `up --obs`):**
  ```bash
  for p in "Tempo:3200/ready" "Loki:3100/ready" "Prometheus:9090/-/ready" \
           "Pyroscope:4040/ready" "OTelcol:13133/" "Grafana:3030/api/health"; do
    n="${p%%:*}"; u="http://localhost:${p#*:}"
    curl -sfm 3 -o /dev/null "$u" && echo "OK   $n" || echo "FAIL $n  $u"
  done
  ```
  Pyroscope and Tempo need ~15 s past process start before `/ready` goes 200 — don't declare failure before then.

## External-call audit DB (`openstudio_obs`)

Separate database on the same local Postgres instance. **Three roles, strict split**:

- `openstudio_obs_owner` — DDL only (migrations). Never used by services.
- `openstudio_obs_writer` — INSERT-only on `external_calls`. Every service's audit RoundTripper uses this DSN.
- `openstudio_obs_reader` — SELECT-only. Admin UI, Grafana datasource.

Provision via `scripts/dev-native/provision-obs-db.sh` — idempotent, uses `pg_roles` existence checks, generates 32-char urandom passwords when `OPENSTUDIO_OBS_*_PASSWORD` env vars are unset and prints them to stderr once. **`ALTER DEFAULT PRIVILEGES FOR ROLE openstudio_obs_owner` is the key** — future tables created by owner automatically grant INSERT to writer and SELECT to reader so migrations don't re-grant per table.

**Verify role isolation after any migration or role-grant edit** — four queries, all must behave as labelled:

```bash
psql "$OPENSTUDIO_OBS_DB_URL"        -c "SELECT 1 FROM external_calls LIMIT 1"  # writer: permission denied
psql "$OPENSTUDIO_OBS_DB_URL"        -c "INSERT INTO external_calls (...) VALUES (...)"  # writer: INSERT 0 1
psql "$OPENSTUDIO_OBS_DB_URL_READER" -c "SELECT count(*) FROM external_calls"  # reader: 1 row
psql "$OPENSTUDIO_OBS_DB_URL_READER" -c "INSERT INTO external_calls (...) VALUES (...)"  # reader: permission denied
```

Any of the four returning the wrong result means a GRANT drifted; fix in the migration, not with ad-hoc psql, so re-provisioning the DB on a clean box reproduces the right state.

### Table shape rules

- **No `req_headers` / `resp_headers` columns, ever.** Headers never land in the DB (ADR §3). A code-reviewed allow-list copies safe values (`Content-Type`, `Retry-After`, `x-ratelimit-*`, `x-request-id`, `openai-processing-ms`) to OTel span attributes only.
- **Bodies are `bytea`**, inlined up to 1 MiB (default `OPENSTUDIO_EXTERNAL_CALL_INLINE_MAX_BYTES`); larger bodies either elide to zero bytes (current state) or carry an `s3-ref:bucket/key` sentinel prefix (Phase 4 wire-up to MinIO).
- **Indexes** cover `started_at DESC`, `trace_id WHERE NOT NULL`, `(peer, started_at DESC)`, and `status_code WHERE status_code >= 400` — the four access patterns the admin UI and Grafana use.

## Audit RoundTripper pattern (Go)

`services/observability/httplog.Wrap` chains onto `obs.WrapTransport` (traces + metrics) and tees request/response bodies into a `dbobs.AsyncWriter`. The invariants:

- **Tee the request body with `io.ReadAll` + `bytes.NewReader` + set `req.GetBody`** — redirects/retries re-read the body, and leaving it on the original stream means the real transport sees empty.
- **Tee the response body via `io.MultiReader(bytes.NewReader(captured), resp.Body)`** so the caller still reads the full response. Capping the capture at `inlineMax+1` via `io.LimitReader` prevents a 1 GiB payload from OOMing the audit path.
- **AsyncWriter.Append must never block.** Full channel → increment drop counter, return false. Insert failure → same. `Close` is idempotent (guarded by `atomic.Bool.CompareAndSwap`), otherwise `defer Close` + explicit `Close` panics with `close of closed channel`.
- **500 ms per-insert timeout** on the pgxpool query. Audit latency must not couple to Postgres health.

## Wiring the audit transport into existing HTTP callers

The audit RoundTripper is useless until each caller actually uses it. The repo has three caller shapes; each needs its own injection surface, and the shape of the surface matters for debuggability.

### Per-vendor callers (ai-gateway providers) — factory keyed on peer, NOT a global transport

Every `services/ai-gateway/*` provider (`anthropictext`, `openaitts`, `elevenlabstts`, `higgsfield`, `localtextgen`, `localvision`, `openaiwhisper`, `openaivision`, `wan21comfy`, …) builds its own `http.Client` inside `New()`. The audit label (`peer` column in `external_calls`) MUST be per-provider for Grafana to be useful.

**Inject via a factory function, not a shared transport variable:**

```go
// services/ai-gateway/transport.go
type HTTPClientFactoryFunc func(peer string, timeout time.Duration) *http.Client
var HTTPClientFactory HTTPClientFactoryFunc = defaultHTTPClientFactory

func NewHTTPClient(peer string, timeout time.Duration) *http.Client {
    if peer == "" {
        panic("aigw.NewHTTPClient: peer label is required")
    }
    return HTTPClientFactory(peer, timeout)
}
```

Each provider's `New()` calls `aigw.NewHTTPClient("anthropic", 10*time.Minute)` with its own stable short label (`anthropic`, `openai-tts`, `elevenlabs`, `higgsfield`, `local-textgen`, `local-vision`, `openai-whisper`, `openai-vision`, `comfyui-wan21`). `apps/api/main.go` swaps `aigw.HTTPClientFactory` at boot inside the obs-wiring block, wrapping with `httplog.Wrap(..., Peer: peer, Writer: obsWriter)`.

**Why factory, not a shared `aigw.DefaultTransport` variable:** a global transport can only carry one peer label, so every AI call lands under `peer="ai-gateway"` or `peer="aigw"` — and Grafana's "which vendor is flaky right now?" query becomes unanswerable. The factory forces per-provider labelling at the API surface. The blank-peer panic enforces that new providers can't ship without declaring their label; a quiet default string would let the invariant rot the moment someone adds a provider in a hurry.

**Carve out `Reachable()` health probes.** They fire on every router decision; auditing them floods `external_calls` with trivial `/models` and `/health` GETs that carry zero debugging value and bury the signal from real inference calls. Build those probe clients inline with `&http.Client{Timeout: time.Second}` and leave a comment pointing at this rule.

### Package-with-one-caller (webhooks) — package-level `Transport` variable

`services/webhooks` has a single `Deliver` function; a factory would be overkill. Expose a package variable instead:

```go
var Transport http.RoundTripper = http.DefaultTransport

func Deliver(ctx context.Context, ep Endpoint, ev Event) (int, string, error) {
    client := &http.Client{Timeout: 10 * time.Second, Transport: Transport}
    ...
}
```

`apps/api/main.go` sets `webhooks.Transport = httplog.Wrap(http.DefaultTransport, httplog.Options{Service: "api", Peer: "webhook", Writer: obsWriter})` in the same obs block as the aigw factory swap. Default to `http.DefaultTransport` so tests and tools that import the package without an obs stack keep working.

### Boot ordering

All of this wiring must land BEFORE provider construction. In `apps/api/main.go` the sequence inside the obs-enabled block is: open obs pool → create `obsWriter` → set `webhooks.Transport` → set `aigw.HTTPClientFactory` → THEN `aigwfactory.NewAuto()` is called later during state init. Setting the factory after `NewAuto()` is a silent no-op — providers cache the client in struct fields at construction time.

## OTel OTLP endpoint — gRPC exporter wants `host:port`, not a URL

The OTel Go SDK's gRPC OTLP exporter (`otlptracegrpc.WithEndpoint(...)`) rejects anything containing `://` with `too many colons in address`. The env var `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:9091` is the HTTP form; many services are configured with that string and pass it straight through, which crashes `obs.Init` on boot with no spans ever reaching Tempo.

**Strip the scheme in `obs.Init` before handing to the gRPC exporter:**

```go
endpoint := o.OTLP
endpoint = strings.TrimPrefix(endpoint, "http://")
endpoint = strings.TrimPrefix(endpoint, "https://")
```

Do the strip inside `obs.Init`, not in every caller — a scheme-tolerant Init means operators can keep the `OTEL_EXPORTER_OTLP_ENDPOINT=http://host:port` form that the OTel HTTP exporter and most docs use, and the gRPC path quietly does the right thing.

## URL redaction (shared Go + Node)

The regex IS the source of truth, not any key list — mirrored byte-for-byte between `services/observability/urlredact.go` and `packages/obs-node/src/redact.ts`:

```
(?i)(key|token|secret|auth|sig|signature|password|credential|access_token|session|code)
```

Values of matching query-param keys are replaced with `[REDACTED]`; everything else (scheme, host, path, non-secret params, fragment) is preserved. **Test with a presigned S3 URL** (`X-Amz-Signature`, `X-Amz-Credential`, `X-Amz-Date`): the first two values must vanish, the date must stay. If `url.Parse` fails, fall back to a `?...&...` string scan so a mangled URL still can't leak.

## Node bridge — never ship DB credentials to Node

`apps/api` exposes `POST /internal/external-calls` guarded by:

1. Loopback-only (`net.ParseIP(remoteHost).IsLoopback()`).
2. HMAC-SHA256 of the raw body, header `X-Internal-HMAC: sha256=<hex>`, keyed on `OPENSTUDIO_EXTERNAL_CALL_INTERNAL_SHARED_SECRET`.

Node (undici dispatcher in `packages/obs-node`) base64-encodes bodies and POSTs the audit payload here. The obs DB credential lives only on the Go side. **Return 204 when the writer is nil (obs DB disabled) and 202 when accepted even on drop** — Node must never retry; a retry would double-fire the real external call.

**Mount the loopback handler at the chi ROOT, not inside `r.Route("/internal", ...)`.** That block has `sessionMiddleware` on it for API-key management, and Node has no session cookie — the HMAC request would 401 before the handler runs. Register it as a sibling: `r.Post("/internal/external-calls", externalCallsHandler(...))` at the top of main's router setup.

## Node package wire-up (`packages/obs-node`)

- **Workspace package versions must align with every consumer's transitive deps.** motion-renderer pulled undici 7 transitively; obs-node pinning `undici ^6` caused pnpm to hoist two copies and `DispatchHandler` types resolved against the wrong one. Match the highest transitive major; verify with `pnpm why undici` from the consumer.
- **Undici 7 renamed the handler type: `Dispatcher.DispatchHandler` (singular). Undici 6 was `DispatchHandlers` (plural).** Dispatcher composition uses `agent.compose((dispatch) => (opts, handler) => dispatch(opts, wrapped))` in both; only the type import changes.
- **`moduleResolution: "Bundler"` means imports omit the file extension.** `import { x } from "./sdk"`, not `"./sdk.ts"`. The latter typechecks under `allowImportingTsExtensions` but breaks at runtime under tsx/node and under consumers who extend `tsconfig.base.json` without that flag. Mirror the surrounding packages — all openstudio TS packages are Bundler-mode.
- **OTel Node SDK (`@opentelemetry/sdk-node@^0.54`, `@opentelemetry/resources@^1.30`) wants `new Resource({...})`, NOT `resourceFromAttributes(...)`** — the latter is 2.x API. Service-name key is `ATTR_SERVICE_NAME` from `@opentelemetry/semantic-conventions`.
- **Disable `@opentelemetry/instrumentation-fs` for motion-renderer.** Remotion opens thousands of files per render; the span volume drowns real signal and inflates OTLP export cost. `getNodeAutoInstrumentations({ "@opentelemetry/instrumentation-fs": { enabled: false } })`.
- **The obs bootstrap must be imported FIRST from the entrypoint.** `import "./obs.js";` at the very top of `worker.ts` / `instrumentation.ts`, before any Temporal/pg/undici import — auto-instrumentation patches modules on first require. Any import above it is uninstrumented for the life of the process.
- **Keep undici OUT of consumer apps' dependency surface.** Expose `installGlobalAuditDispatcher()` from obs-node that calls `setGlobalDispatcher` internally. `apps/web`'s `instrumentation.ts` has no reason to import undici directly, and adding it to `apps/web/package.json` just to call `setGlobalDispatcher` creates a second version pin to manage.
- **Next.js 15 instrumentation hook must guard the runtime.** `if (process.env.NEXT_RUNTIME !== "nodejs") return;` at the top of `register()` — the Edge runtime calls `register()` too but lacks the Node APIs the OTel SDK needs, and the ensuing error aborts cold start of every Edge route.

## Retention cleaner (`services/db-obs/retention`)

Separate budgets for success rows (default 90 d) and error rows (default 365 d — the ones you re-open old tickets about). Owner DSN required (writer/reader lack DELETE).

- **Set `statement_timeout` as a pgxpool RuntimeParam, not a session SET.** `pool.Exec(ctx, "SET statement_timeout = '10s'")` only affects that one checked-out connection; the next DELETE batch pulls a fresh conn without it. Correct form:

  ```go
  cfg.ConnConfig.RuntimeParams = map[string]string{"statement_timeout": "10000"}  // ms, as string
  ```

  Value is milliseconds, serialised as a string — Postgres accepts both numeric-ms and `'10s'` forms, but RuntimeParams go through libpq-style startup packet which prefers the numeric form.
- **Batched DELETE with explicit yield** so writers aren't starved: delete `LIMIT 10000`, sleep 100 ms, repeat until the tag's `RowsAffected()` drops below the batch size. Driving it off `IN (SELECT id ... LIMIT N)` keeps the plan on the `started_at` index.
- **Log the resolved budgets BEFORE calling `retention.Run`.** The Options defaults inside the package rewrite `0 → 90d / 365d`, so a mis-set env var looks successful in the "removed=0" log line. Print `success_days` / `error_days` as the CLI resolved them, from the CLI not from Run.

## Grafana datasource for `openstudio_obs`

Add a 5th provisioned datasource (postgres type) pointing at the SELECT-only reader role so dashboards can query raw audit rows. Password resolves at Grafana startup from `OPENSTUDIO_OBS_READER_PASSWORD` — the datasource YAML carries `${OPENSTUDIO_OBS_READER_PASSWORD}`, nothing hardcoded. `postgresVersion: 1800` for Postgres 18 (Grafana rejects unknown versions).

Dashboards that query it set `datasource: { type: "postgres", uid: "openstudio-obs-reader" }` and use `$__timeFilter(started_at)` for the time range. Percentile queries use `percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)` — Postgres aggregate, not Grafana's `$__histogramQuantile`.

## Shell gotcha — generating passwords under `set -o pipefail`

`tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32` dies with exit 141 (SIGPIPE) because `tr` keeps writing after `head` closes. On macOS `tr` also hits `Illegal byte sequence` on raw bytes without `LC_ALL=C`. Correct form:

```bash
gen() { LC_ALL=C head -c 96 </dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32 || true; }
```

Read a fixed-size prefix first, pipe through `tr` with `LC_ALL=C`, trim with `head -c N`, swallow the SIGPIPE with `|| true`.

## Sentry error tracking (per-service projects)

OTel owns traces/metrics/logs; Sentry owns ERROR events. Keep them separate: `TracesSampleRate=0` on the Sentry client so Sentry never captures a performance transaction, and tag every event with the OTel `trace_id` (`sentry.CurrentHub().Scope().SetTag("otel.trace_id", ...)`) so Grafana ↔ Sentry are deep-linkable at the event level.

### DSN model — one Sentry project per app, not one tagged project

Each long-running app gets its OWN Sentry project (separate quotas, alert routing, release graphs, PagerDuty rules). A single DSN tagged by `service.name` collapses alerting across services and makes per-service quota tuning impossible. Config exposes:

```
OPENSTUDIO_SENTRY_DSN_API            → apps/api
OPENSTUDIO_SENTRY_DSN_WORKER_CORE    → apps/worker-core
OPENSTUDIO_SENTRY_DSN_WORKER_RENDER  → apps/worker-render/motion-renderer
OPENSTUDIO_SENTRY_DSN_SCHEDULER      → apps/scheduler
OPENSTUDIO_SENTRY_DSN_BACKEND        → fallback when a per-service override is empty
OPENSTUDIO_SENTRY_DSN_WEB            → apps/web (separate from backend)
```

`services/config.Config.SentryDSNFor(service)` is the single resolution point — per-service override wins, else `_BACKEND`, else empty (SDK disabled). Every service's `obs.Init` call reads from this helper; never pass `cfg.SentryDSNBackend` directly or you've silently collapsed projects.

### `services/observability/sentryx` package shape

One subpackage inside `services/observability`, shared by every backend app:

- `Init(Options{DSN, Environment, Release, ServerName}) (shutdown func(ctx) error)` — nil-safe. Empty DSN returns a no-op shutdown without initialising the SDK; a local-dev boot with no DSN costs zero network traffic.
- `Enabled() bool` — must check `client.Options().Dsn != ""`, NOT `client != nil`. **The sentry-go SDK auto-binds a default DSN-less client at package init**, so a bare `CurrentHub().Client() != nil` check reports enabled when the SDK is actually dormant, and Capture paths spin up unused scopes on every error.
- `CaptureError(ctx, err, tags)` — reads any live OTel span from ctx and attaches `otel.trace_id` / `otel.span_id` as tags.
- `Recover(ctx, tags)` — deferred panic handler; captures then re-panics so the caller's own recovery (chi.Recoverer, Temporal activity return) still runs. Never swallow the panic in sentryx — writing to the ResponseWriter here races the middleware stack above.
- `HTTPMiddleware()` — chi evaluates middlewares outer→inner in `r.Use()` order, so `middleware.Recoverer` MUST be registered FIRST (outer) and `sentryx.HTTPMiddleware()` SECOND (inner). The inner deferred recover runs first, captures to Sentry, re-raises; the outer Recoverer catches the re-raised panic and writes 500. Reverse the order and Recoverer swallows the panic before sentryx's defer ever sees `recover() != nil` — zero HTTP events reach Sentry in production even though the SDK is initialised. The common wrong intuition is 'install before Recoverer so Sentry sees it first' — `r.Use` order is NOT execution order, it is registration order, which runs outer-to-inner. Pin the correct order with an integration test that chains both middlewares and asserts a captured event, not with a mock recoverer that re-raises (a mock does not reproduce chi.Recoverer's swallowing behaviour).
- `SlogHandler{Inner}` — bridges slog ERROR records to `hub.CaptureMessage` with the record's structured attrs on a single `slog_attrs` Context block, plus the OTel trace_id tag. Install it in `obs.Init` by wrapping EVERY handler path (the no-OTel branch, the OTel teeHandler branch, and the OTel-exporter-failed fallback) — one wrap helper, three call sites, so adding another branch doesn't silently miss the bridge.

### sentry-go v0.50 API drift pitfalls

- `Event.Extra` and `Scope.SetExtra` were REMOVED. Use `Scope.SetContext(name, sentry.Context)` where `sentry.Context = map[string]any`. A single `slog_attrs` Context block carrying all record attrs is cleaner than per-key extras and survives scrub.
- `Transport.Flush` takes `time.Duration`, not `any`. A fake transport in tests must match the real signature exactly or the test won't compile with a cryptic "wrong type for method" error that doesn't mention the arity.
- `BeforeSend` scrubs `event.Request.Data = ""`, `event.Request.QueryString = ""`, `event.Request.Cookies = ""`, and filters `event.Request.Headers` against a case-insensitive sensitive-header set (`authorization`, `cookie`, `set-cookie`, `proxy-authorization`, `x-api-key`, `x-auth-token`, `x-session-token`) replacing matches with `"[filtered]"`. Then iterate `event.Contexts` deleting keys whose name ends in `_body` / `_payload`. `Cookies` is a dedicated top-level field in the sentry-go HTTP event schema (NOT inside `Headers` — `SetRequest` moves the Cookie header into it), so a header-only scrub leaves session tokens shipping to Sentry on every captured 500. `QueryString` carries tokens from `?token=...` / `?api_key=...` style URLs. Keep this list conservative — easier to add another sentinel than to retract an event already shipped. Mirror the same policy on the Node side (`apps/web/lib/sentry-scrub.ts`, `apps/worker-render/motion-renderer/src/sentry.ts`) so Go and Node emit interchangeable scrubbed events.

### Boot ordering inside `obs.Init`

Sentry init MUST come before `slog.SetDefault` so the bridging slog handler sees the initialised client. Compose the final slog handler as `sentryx.SlogHandler{Inner: <existing>}` and chain `sentryShutdown` into the returned shutdown func. The slog bridge is cheap when Sentry is off, so install it unconditionally — one path to maintain, not two.

## Cross-boundary trace continuity — verify, don't trust the ADR

Traceability across a message-bus boundary (Temporal, Kafka, SQS) does NOT come free from OTel SDK auto-instrumentation. The ADR may spec the interceptor; grep the code before trusting it:

```sh
rg -n 'NewTracingInterceptor|tracing-interceptor|interceptors-opentelemetry' apps/
```

Zero hits means the API → workflow → activity trace graph is severed at the Temporal hop, and Sentry events on the worker side carry a trace_id that doesn't match the user's request in Tempo. When wiring Sentry or any cross-service error tracking, verify the OTel propagation hops first — a plan built on "traces already flow end-to-end" when they don't produces unlinkable events.

### Temporal Go SDK — install the interceptor on BOTH sides

`go.temporal.io/sdk/contrib/opentelemetry` ships `NewTracingInterceptor(TracerOptions{})` returning `interceptor.Interceptor` (the combined `ClientInterceptor`+`WorkerInterceptor` type).

- **Client side** (API, scheduler, worker-core all dial Temporal): add to `client.Options.Interceptors` on `client.Dial`. Without this, `ExecuteWorkflow` starts a child span the workflow side never sees.
- **Worker side** (worker-core registers workflows + activities): also add to `worker.Options.Interceptors` on `worker.New`. Without this, activity spans hang orphaned at the activity entry point instead of parenting off the workflow span.

Same interceptor instance can be reused for both — one `NewTracingInterceptor` call, two attachments. `NewTracingInterceptor` only errors on invalid `TracerOptions`, so empty opts cannot fail; `slog.Error` + continue the boot rather than exit — losing the interceptor should degrade traceability, not take the API down.

### Node side (worker-render) — mirror the pattern

`@temporalio/interceptors-opentelemetry` provides matching client + worker interceptors. Install on `Connection.connect` AND on `Worker.create` options. Same pitfall: ADR 0012 §4.2 may spec it; grep `node_modules`/`package.json`/`src/` for `interceptors-opentelemetry` to confirm it actually ships.

- **Import path is `@temporalio/interceptors-opentelemetry/lib/worker/index.js`, not the bare `/worker` subpath.** The package has no top-level `exports` map for the subpath; Bundler-mode TS resolves it, but tsx and node ESM runtime both fail on `/worker` with `Cannot find module`. Use the full `lib/worker/index.js` form.
- **`Context.current().info.workflowExecution` is nullable in the activity typings.** Access via optional chaining (`info.workflowExecution?.workflowId ?? ""`) when building Sentry tags — a bare field access fails `tsc --strict` with `'info.workflowExecution' is possibly 'undefined'`.
- **Wrap each activity in a `withSentry(name, fn)` try/catch so terminal errors capture tagged with workflow_id / run_id / attempt from `Context.current().info` BEFORE Temporal's error path.** The OTel inbound interceptor only parents the span; capture is user code. Re-throw the error after capture so Temporal's retry/terminal semantics are unchanged.
- **`@sentry/node` v8 auto-installs HTTP + Express integrations.** A worker process that doesn't run an HTTP server has those integrations starting spans Sentry doesn't need (and that duplicate OTel's HTTP tracer). Filter them out in `Sentry.init`:
  ```ts
  integrations: (defaults) => defaults.filter((i) => i.name !== "Http" && i.name !== "Express"),
  ```
- **Install process-level `uncaughtException` + `unhandledRejection` handlers after `Sentry.init`.** Node's default crash path exits before an unflushed event ships; `Sentry.flush(2_000)` inside the handler before `process.exit(1)` keeps the event. Match Node's semantics for rejections (log + continue, do NOT exit) — a stray rejection in a dep must not nuke the worker. On the rejection branch call `void Sentry.flush(2_000)` fire-and-forget (do NOT await) so a SIGKILL/OOM that lands next still gets the earlier event out.
- **Node signal listeners FAN OUT — Node runs EVERY registered listener for a given signal, not first-handler-wins.** A SIGTERM handler in `obs.ts` that calls `flushAll().finally(() => process.exit(0))` will race any sibling handler (e.g. `worker.ts` draining Temporal) and `process.exit` wins by whichever microtask queue flushes first — killing in-flight work mid-drain. Only the long-running entrypoint owns signal handlers; the obs bootstrap module exports `flushAll()` and the entrypoint calls it as the LAST step of its own shutdown (after Temporal drain + health-server close). A one-shot script that imports obs.ts directly can register signal handlers; a long-running worker that imports it cannot have the module register its own.

## Phased rollout — commit boundaries

## apps/web Sentry (Next.js 15 + @sentry/nextjs v11)

- **`withSentryConfig` moved to the `/config` subpath in v11+.** `require("@sentry/nextjs")` returns runtime helpers only; `withSentryConfig` is undefined at the top level and crashes `next.config.js` load with `TypeError: withSentryConfig is not a function`. Import as `const { withSentryConfig } = require("@sentry/nextjs/config")`. The subpath exists in the package's `exports` map; grep `node_modules/@sentry/nextjs/package.json` to confirm when the SDK upgrades again.
- **Three config files, one shared scrub.** `sentry.client.config.ts`, `sentry.server.config.ts`, `sentry.edge.config.ts` each gated on their DSN env and importing a single `lib/sentry-scrub.ts` that mirrors `services/observability/sentryx` scrub policy. Keep the shared scrub typed as `ErrorEvent` (not `Event`) — `@sentry/nextjs` v11 split event types and the generic `Event` is not assignable to the `beforeSend` callback signature.
- **Register BOTH `beforeSend` AND `beforeSendTransaction` in every config file.** `@sentry/nextjs` v11 routes performance envelopes through `beforeSendTransaction`, which is NOT invoked by `beforeSend`. Dormant while `tracesSampleRate=0`, but the moment anyone bumps browser or server tracing on, `request.data` / `query_string` / `cookies` on transaction envelopes ship unscrubbed. Wire the pair now so a future tracing enable can't bypass the scrub.
- **`TransactionEvent` is exported from `@sentry/core`, not re-exported by `@sentry/nextjs`.** Pulling `@sentry/core` as a direct dep just for the type is overkill; structurally model the subset the scrub actually touches (`{ request?: ErrorEvent["request"]; extra?: Record<string, unknown> }`) and cast the function at the `Sentry.init` call site with `beforeSendTransaction: scrub as any`. One scrub body serves both event shapes because they share the fields the scrub needs.
- **`instrumentation.ts` loads the matching Sentry config at the right runtime.** `register()` imports `./sentry.server.config` under `nodejs` and `./sentry.edge.config` under `edge`; neither at build time, both inside the runtime guard. OTel's `registerNode()` runs FIRST on the Node branch (auto-instrumentation patches modules on first require), Sentry second.
- **`onRequestError` is Next 15's hook for route-handler / server-action / server-component throws.** Export it alongside `register()` from `instrumentation.ts` and dynamically import `@sentry/nextjs` inside the handler to call `Sentry.captureRequestError(err, request, context)`. Without this hook, server errors bubble into Next's error boundary and never reach Sentry even though the SDK is initialised.
- **CSP wildcards match EXACTLY ONE label — region-scoped Sentry hosts (post-2024 orgs) need explicit entries.** Sentry orgs created since mid-2024 resolve DSNs to `o<id>.ingest.us.sentry.io` or `o<id>.ingest.de.sentry.io` (5 labels). `https://*.ingest.sentry.io` only matches 4-label legacy hosts; the browser SDK's envelope POST is blocked by CSP and errors never leave the browser (no console error — the SDK sees the request as failed and silently retries into oblivion). `connect-src` must list both tiers explicitly: `https://sentry.io https://*.sentry.io https://*.ingest.sentry.io https://*.ingest.us.sentry.io https://*.ingest.de.sentry.io`. Alternative escape hatch: `tunnelRoute: '/monitoring'` in `withSentryConfig` so Sentry traffic is same-origin and no CSP tuning is needed. Also required: `https://*.highlight.io https://pub.highlight.io wss://*.highlight.io` for Highlight ingest.
- **Highlight needs `worker-src 'self' blob:` — its event pipeline runs in a Web Worker constructed from a Blob URL.** Without the directive, workers fall back through `child-src` → `script-src`, and if neither has `blob:`, the worker fails to instantiate under enforcing CSP and session capture silently stops with a `Stopping recording due to worker failure` console error. Keep `blob:` isolated to `worker-src` — do NOT widen `script-src` to include `blob:` (that lets any blob URL execute as a script). The directive is additive: `"worker-src 'self' blob:"` as its own line in the CSP array.
- **`sourcemaps.disable=true` suppresses the auth-token requirement.** `withSentryConfig(cfg, { sourcemaps: { disable: true } })` ships without uploading source maps; stack traces are minified in Sentry until a CI PR wires `SENTRY_AUTH_TOKEN`. Documented beta limitation — do not try to work around it by setting a dummy token.
- **`silent: !process.env.CI` keeps local dev quiet.** The Sentry webpack plugin prints a banner on every build otherwise; local dev becomes noisy and the real build output scrolls off.
- **Highlight `tracingOrigins` as a bare JSX boolean attaches `tracestate`/`traceparent` headers to EVERY outbound fetch — including third-party CDNs — and trips CORS preflights that weren't previously needed.** Default of `true` is `tracingOrigins={true}`, which Highlight expands to all origins. Scope explicitly to same-origin only with `tracingOrigins={[/^\//]}` (or the specific origins you own). Same rule: `networkRecording.recordHeadersAndBody: false` is the policy — Highlight must never capture request/response bodies.

## Config fallback when `config.Load()` returns `ConfigError`

`services/config.Load()` returns `(nil, &ConfigError{...})` when a REQUIRED env var is missing — the config pointer is nil, not partial. A `cfgErr != nil && !config.IsConfigError(cfgErr)` guard that falls through to use `cfg.*` deref-panics at boot because `cfg == nil`. Services that only need a subset of config (worker-core, scheduler) must BUILD a minimal fallback `*config.Config` populated from `os.Getenv` + sensible defaults BEFORE touching any field; services that are the strict consumers (api) must exit on any `cfgErr`. The 'soft-fail and keep going' comment without an actual fallback struct is the common wrong shape — if the code says soft-fail, the fallback struct must exist in the same block.

## Phased rollout — commit boundaries

For multi-phase infra work in this repo, one commit per phase on a feature branch keeps diffs reviewable and reverts surgical. The order ADR 0012 followed and that generalises:

1. ADR + plan (docs only).
2. Config schema extension (new env vars + validation, nil-safe defaults).
3. Local infra scaffolding (dev-native boot + binary install).
4. Shared library (SDK/middleware) with tests.
5. Audit/persistence layer (DB provisioner + migration + Go client + integration test).
6. API glue (loopback endpoints, boot wiring).
7. Downstream integration (Node package, Next.js instrumentation).
8. Polish (dashboards, alerts, retention jobs, lint gates).

Steps 2–7 each build and test independently; a reviewer can bisect without untangling cross-concern changes.
