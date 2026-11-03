# Dev services, launch commands, and ports

`scripts/dev-native/up.sh` boots the **infra tier only** — Postgres, Redis, MinIO, Temporal, Mailpit — plus goose migrations and MinIO bucket init. It does NOT start any application process. Every app tier below is launched by hand (or by a supervisor the operator wires up).

## Full topology (what the operator actually needs running)

| Tier | Service | Launch | Port | Notes |
|---|---|---|---|---|
| infra | Postgres 18 | `up.sh` | 5432 | db `openstudio`, role `openstudio`, superuser is `$USER` |
| infra | Redis | `up.sh` | 6379 | |
| infra | MinIO API | `up.sh` | 9000 | `minioadmin`/`minioadmin` |
| infra | MinIO Console | `up.sh` | **9002** on this VM (the script passes `--console-address :9001` but minio has rebound; verify with `lsof -nP -iTCP -sTCP:LISTEN \| grep minio`) | |
| infra | Temporal gRPC | `up.sh` | 7233 | namespace `default` — see SKILL.md invariant |
| infra | Temporal UI | `up.sh` | 8233 | |
| infra | Mailpit SMTP | `up.sh` | 1025 | |
| infra | Mailpit UI | `up.sh` | 8025 | |
| app | API (Go) | `go run ./apps/api` | 4000 | `API_PORT` in `.env` |
| app | Web (Next.js 15) | `pnpm --filter @openstudio/web dev` | **3001** (hardcoded in package.json `next dev --turbo -p 3001`) | `WEB_PORT=3000` in `.env` is a LIE — the dev script ignores it |
| app | Worker-core (Go) | `go run ./apps/worker-core` | — | polls Temporal queue `pipeline`, namespace `default` |
| app | Worker-render / motion (Node) | `pnpm --filter @openstudio/motion-renderer dev` (or `cd apps/worker-render/motion-renderer && pnpm dev`) | — | polls Temporal queue `render`, namespace `default`; dotenv load required (see SKILL.md). Renders Remotion compositions — motion-graphics kind. |
| app | Worker-render / cinematic (Go) | `cd apps/worker-render/cinematic-renderer && go run .` | — | polls Temporal queue `cinematic`, namespace `default`. Required for cinematic + influencer-video submits; without it workflows ScheduleToStart-timeout. |
| design | Storybook | `pnpm --filter @openstudio/web storybook` | 6006 | design system lives inside `apps/web`, not `packages/ui` |
| design | Remotion Studio | `pnpm --filter @openstudio/compositions dev` | **3000** | COLLIDES with any other dev server grabbing 3000 — launch after Next (which pins 3001) so the collision only costs you Remotion |
| ops | Mailpit UI | see infra | 8025 | there is NO docs server; `docs/` is plain markdown — browse in editor |

## Rules

- **Stop brew-managed Postgres/MinIO/Temporal/Redis/Mailpit BEFORE running `up.sh`.** Fresh macOS installs via `scripts/bootstrap-macos.sh` leave these as brew services (`brew services list` shows `started`), each listening on the exact port `up.sh` wants (5432, 9000, 7233, 6379, 1025). `up.sh` does NOT detect them — it tries to boot its own supervised copy and silently fails or binds to a different port (seen: MinIO rebinding to `:9002`, Postgres `up.sh` detects running and skips cluster init but then runs goose against the brew-managed cluster). Procedure before every fresh `up.sh`:

  ```bash
  brew services list | awk '/^(postgresql@18|minio|temporal|redis|mailpit)\s+started/ {print $1}' \
    \| xargs -r brew services stop
  sleep 3
  lsof -nP -iTCP:5432 -iTCP:9000 -iTCP:7233 -sTCP:LISTEN     # must print nothing
  scripts/dev-native/up.sh --obs
  ```

  Symptom when skipped: `up.sh` prints `✓ OpenStudio dev stack is up` but `MinIO console :9001` is dead (brew's old process holds :9002), goose migrations run but tables live in the brew-managed cluster at `/opt/homebrew/var/postgresql@18` rather than `scripts/dev-native/state/postgres/data`, and `scripts/dev-native/down.sh` later only stops the supervised processes — leaving zombie brew processes to re-collide on next boot.
- **Export `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8` before `up.sh` from a Hermes terminal.** Without it Postgres 18 dies at boot with `FATAL: postmaster became multithreaded during startup` / `HINT: Set the LC_ALL environment variable`, `pg_ctl` prints `could not start server`, and the script aborts before Redis/MinIO/Temporal start.
- **Before starting worker-core in `AI_PROVIDER_MODE=real`, check for stale Running workflows** (`temporal workflow list --namespace default --query "ExecutionStatus='Running'"`) and `queued`/`running` rows in `content.renders` grouped by project kind. A leftover cinematic `GenerateVideoWorkflow` on queue `pipeline` resumes the moment worker-core polls and dispatches to Higgsfield. Ask the user first; when they say cancel, run `temporal workflow terminate` and `UPDATE content.renders SET status='cancelled', cancelled_at=now()`.
- **After `goose up` as `$USER` on this VM, grant schema USAGE + table privileges to `openstudio` or every pre-auth operation 500s with `permission denied for schema platform (SQLSTATE 42501)`.** The RLS migration (00050-ish) grants `USAGE ON SCHEMA platform, content, billing, catalog` to `openstudio_app` ONLY. The `openstudio` login role (owner-pool, `BYPASSRLS`, used for CreateSession, API-key mint, every pre-auth path) is assumed to OWN the schemas — but `scripts/dev-native/up.sh` runs `goose up` as `$USER` (sa-vm), so sa-vm owns everything and `openstudio` has no schema USAGE. Visible symptoms: boot log full of `WARN auth sweep: sessions: permission denied for schema platform`, boot log `EnsureDemoTenant failed: seed user: ERROR: permission denied`, and — the one the user actually hits — sign-in returns `{"error":{"code":"INTERNAL","message":"mint session","retryable":false}}` because `platform.sessions` INSERT fails on schema USAGE. `/readyz` is still green because the readyz probe uses a `SELECT 1` not a schema-qualified query. Fix once per fresh cluster, as the cluster superuser:

  ```sql
  GRANT USAGE, CREATE ON SCHEMA platform, content, billing, catalog TO openstudio;
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
    ON ALL TABLES IN SCHEMA platform, content, billing, catalog TO openstudio;
  GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA platform, content, billing, catalog TO openstudio;
  -- Future tables created by $USER (migrations) inherit the grant:
  ALTER DEFAULT PRIVILEGES FOR ROLE "$USER" IN SCHEMA platform, content, billing, catalog
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO openstudio;
  ALTER DEFAULT PRIVILEGES FOR ROLE "$USER" IN SCHEMA platform, content, billing, catalog
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO openstudio;
  ```

  No API restart needed — pgx re-reads catalog per statement. The migration itself should grow this grant (CI's new `migrations` job runs `goose up` as the same role it then queries with, so it does not catch this).
- **Restarting the API: kill the compiled child, not just `go run`.** `go run ./apps/api` forks `/var/folders/.../go-build*/b001/exe/api`; `pkill -f 'go run ./apps/api'` kills the wrapper and leaves the child listening on :4000 with the OLD code. Every later request — including a "verify the fix" request that can spend on a vendor — hits stale code. Do `pkill -f 'exe/api'` as well, confirm `lsof -nP -iTCP:4000 -sTCP:LISTEN` is empty, then start with `go build -o /tmp/os-api ./apps/api && /tmp/os-api` so the PID is unambiguous and `ps -o lstart -p <pid>` can be compared to `git log -1 --format=%ci`. Never run a request that can reach a paid vendor without the user's explicit go-ahead for that run, and never before this check passes.
- **`pkill -f "apps/api"` is too broad — every app worker's command line contains `apps/`.** `go run ./apps/worker-core`, `go run ./apps/scheduler`, `go run ./apps/worker-render/cinematic-renderer`, and `pnpm --filter @openstudio/motion-renderer dev` (whose compiled tsx wrapper references `apps/worker-render/motion-renderer`) ALL match `-f "apps/"`-shaped patterns. One pkill wipes every Go worker on the box; the API comes back on restart but the Temporal queues (`pipeline`, `render`, `cinematic`) have no pollers, so the next workflow sits ScheduleToStart-timeout and `content.renders` ends up `failed` with `WORKFLOW_FAILED: context deadline exceeded`. The retry button then kicks a fresh workflow that also hangs — and the "my retry did nothing" bug report is actually "you killed every worker." Target by compiled binary name (`pkill -f 'exe/api'`), by the exact relative path (`pkill -f 'go run ./apps/api$'`), or best, by the PID returned when the process was backgrounded (`terminal(background=True)` yields a `session_id` + `pid` — kill THAT). After any API restart, `ps aux | grep -E 'worker-core|cinematic-renderer|motion-renderer|scheduler'` to confirm the four workers are still up before accepting a user retry.
- **If a bad job did reach a vendor:** stop the API immediately; park the queued follow-up photos so finalise-on-read can't start them (`UPDATE content.influencer_photos SET status='failed', failure_reason='Held back — not started.' WHERE influencer_id=$1 AND status='waiting'`); report the request id, influencer id and the prompt that went out BEFORE touching anything else; the user decides between viewing, cancelling via the adapter's `Cancel`, or deleting (DELETE /influencers/{id} does not cancel the vendor job).

- **`up.sh` is infra-only — never tell the operator the stack is "up" after running it alone.** The API, web, workers, Storybook and Remotion Studio are each separate processes; a bare `up.sh` leaves every HTTP surface at port 4000/3001/6006/3000 unanswered. For a full "everything running" state, launch each app-tier row above and verify with `lsof -nP -iTCP -sTCP:LISTEN`.
- **`apps/worker-render/` holds TWO renderers on TWO queues — launch both, or document that you only need one.** The directory contains `motion-renderer/` (Node/Remotion, queues `render` + `render-engine`) AND `cinematic-renderer/` (Go `main`, queue `cinematic` — it has no `package.json`, so a missing one there is expected, not evidence the renderer lives inside worker-core). A bare `cd apps/worker-render && pnpm dev` only starts the Node motion-renderer because that's the directory pnpm resolves against; the cinematic queue then has zero workers and every cinematic / influencer-video submit sits at `ScheduleToStartTimeout` forever (symptom: `POST /cinematic/projects/{id}/render` returns 202, the workflow row shows `WorkflowTaskScheduleToStart` in Temporal UI, no activity ever runs). If a smoke test only exercises motion-graphics / stage pipeline, you can skip the cinematic renderer and say so; if ANY cinematic submit is in the test plan, both are mandatory.
- **Ignore the Taskfile's `dev` / `dev:down` / `logs` targets on this VM — they are Docker-Compose wrappers and there is no Docker.** "Start everything" = infra already up (check `ps -eo command | grep -E 'postgres -D|redis-server|minio server|temporal server|mailpit'`) + each app-tier row above launched by hand. Launch Go app processes from a prebuilt binary, not `go run`, for every one of them (`go build -o /tmp/os-<name> ./apps/<name>` then `set -a; . ./.env; set +a; exec /tmp/os-<name> >> scripts/dev-native/state/logs/<name>.log 2>&1` with `background=true`) so the PID Hermes returns is the real server and `kill` hits the right process; launch the motion renderer the way the Dockerfile does (`node --import tsx src/worker.ts` from its dir). Verify in a second call: `/healthz` on :4000, web on :3001, `worker ready` / `Started Worker … TaskQueue` lines in the logs. Every app log fills with OTel `exporter export timeout … connection refused` / `PeriodicExportingMetricReader … UNAVAILABLE` when the obs stack is down — expected noise, not a fault; `up.sh --obs` silences it.
- **`apps/scheduler` is a one-shot, not a daemon.** It runs under `--run-once` from a cron/launchd caller; do not add it to a long-running supervisor or expect to see it in `ps`.
- **Remotion Studio defaults to :3000 and will steal that port if the web dev server is misconfigured.** `apps/web`'s dev script is pinned to `-p 3001`, so the collision never happens in practice — but if you ever strip the `-p` flag from `apps/web/package.json`, Next will grab 3000 first and Remotion Studio will silently roll forward to the next free port (3002, 3003, …), breaking any hardcoded `http://localhost:3000` dev links.
- **The design system is Storybook under `apps/web`, not `packages/ui`.** `packages/ui` has only `typecheck` — stories live in `apps/web/.storybook`. Do not look for `pnpm --filter @openstudio/ui storybook`; there isn't one.
- **Launch background app processes via Hermes's `background=true`, not shell `nohup ... &`.** Covered in SKILL.md (shell-level backgrounding is refused). The usual belt-and-braces for Node is `set -a; . ./.env; set +a` in the same call before `pnpm dev` so the shell exports `.env` even if in-process dotenv is misconfigured.
- **Dev log paths MUST be gitignored before launching.** If you redirect app stdout/stderr into a repo-relative path (`.runlogs/`, `tmp/`, `.logs/`, `/tmp` symlinks inside the tree), the next unscoped `git add -A` on a feature branch quietly commits those binary-ish log files alongside the real diff. Rescue requires `git reset --soft HEAD~1 && git rm -rf --cached <dir>/ && git commit`, which blurs the feature commit's history. Before the first launch of a session: `grep -q runlogs .gitignore || echo '.runlogs/' >> .gitignore` (or point the logs at `$BH_AGENT_WORKSPACE` / `~/.hermes/cache/scratch/`, which are outside the repo). Same rule for `/tmp/os-api` binaries used by the restart-the-API dance — they are already outside the tree, which is why that pattern survives `git add -A`.
- **Before declaring "nothing can spend", check for already-running workers.** `ps aux | grep -E 'worker-core|worker-render|tsx.*watch'` and look at the DB backlog (`select status,count(*) from content.renders group by 1`). A leftover worker holding the vendor key plus hundreds of `queued` rows is a live-spend risk even when your own API runs with the key unset. Report it and ask before starting or stopping any worker.
- **When the harness browser shows the fix but the user says it's still broken, restart the dev servers before debugging further.** Turbopack can keep serving stale chunks to a long-lived user tab (shell/layout edits especially); the headless harness loads fresh and hides it. `pkill -f 'next dev'; rm -rf apps/web/.next; pnpm --filter @openstudio/web dev` plus an API restart (kill `exe/api` too — SKILL.md), then ask for a hard refresh — only then compare DOM probes. The user wants layout fixes confirmed in a real browser, not only the harness; say which you used.
- **Shell `NODE_ENV=production` carried from the operator's `.zshrc` silently flips the API into prod-defaults mode and makes dev-only features vanish from `/create`.** `services/config.Load` branches on `prod := os.Getenv("NODE_ENV") == "production"` and uses that as the FALSE branch for every `getenvBool("FEATURE_X", !prod)` default. In-process godotenv does NOT override already-set env vars, so an exported `NODE_ENV=production` in the shell beats the repo `.env`'s `NODE_ENV=development`. Symptom: a tile is missing from `/create`, `/internal/me` returns `features.<x>: false`, zero errors anywhere, and the only diagnostic is `ps eww -p <api-pid> | tr ' ' '\n' | grep NODE_ENV`. Fix: launch the API with `env -u NODE_ENV go run ./apps/api` for the session, and scrub the shell rc so the next session doesn't repeat the carry-over. Same mechanism as the vitest NODE_ENV leak in apps/web test gotchas below, opposite direction (there dev leaks into tests; here prod leaks into dev).
- **Verify readiness in a SEPARATE call, not with `sleep && curl` inside the launch call.** Launch returns immediately when backgrounded; a follow-up `lsof` or `curl /healthz` call tells you whether the port is actually listening. Chaining them hides which stage failed.

## Health + readiness probe contract

Every long-running service exposes `/healthz` (cheap liveness — 200 whenever the process is up, touches NO dep) and `/readyz` (dep fan-out, 2s per-check deadline, 200 only when every CONFIGURED dep responds). Payload shape is identical across services and must stay that way:

```json
{ "ok": true, "service": "<name>", "version": "...",
  "checks": { "<dep>": { "status": "ok|fail|timeout|disabled", "detail": "..." } } }
```

Reference implementation is `apps/api/healthz.go` — mirror its status taxonomy and timeout constant verbatim when adding a probe to a new service. Ports (one convention, don't collide): api `:4000`, worker-core `:4100`, worker-render `:4101`, scheduler `:4102`. Env override: `WORKER_CORE_HEALTH_ADDR` / `WORKER_RENDER_HEALTH_ADDR` / `SCHEDULER_HEALTH_ADDR`; empty string disables the probe server so `--run-once` and short test harnesses don't fight for a port.

- **`disabled` must NOT fail readiness.** A nil dep (feature-off-by-config: no `DATABASE_URL`, no Temporal client, in-memory dev mode) is reported `disabled` and treated as a pass. Otherwise every dev-mode boot 503s and the probe is useless — which is the whole point of having one.
- **Shutdown-draining state is a readyz fail, not an ok.** On the Node worker-render, combine the Temporal probe (`connection.workflowService.getSystemInfo({})`) with `worker.getState() === "RUNNING"`; anything else (STOPPING/STOPPED/FAILED) returns `fail` so the LB stops routing while the pod drains. Same principle for any service with a lifecycle state: readiness tracks "can serve new work right now", not "process is alive".
- **`go doc` the real SDK signature before writing a fake that implements it.** The Go Temporal SDK's `client.Client.CheckHealth` is a two-arg method, NOT variadic `grpc.CallOption` — guessing wrong from grpc-ish instincts yields a fake that doesn't satisfy the interface and the test won't compile. `go doc go.temporal.io/sdk/client.Client.CheckHealth` is the one-liner that pins the shape.
- **Prove 503 with injected failing fakes, not by killing live deps.** The unit test for a /readyz check must stub the dep with an always-erroring adapter and assert status 503 + `checks.<dep>.status=="fail"` + non-empty `detail`. Do NOT kill the user's live Postgres / Temporal / MinIO to "prove the fail path" — a running dev stack is shared state and the fake path exercises the same code.

## Public ingress for vendor webhooks (Tailscale Funnel)

Local dev needs a stable public HTTPS URL whenever a vendor delivers webhooks back to the API — social-publishing aggregators (Zernio), payment providers (Stripe), OAuth callbacks that reject `localhost`. **Tailscale Funnel is the standing answer on this VM**: already installed (`/usr/local/bin/tailscale`), stable URL across restarts (same `*.ts.net` host forever), free, no third-party account.

One-time per tailnet (admin console → ACLs, keep in the saved file):

```json
"nodeAttrs": [
  { "target": ["autogroup:member"], "attr": ["funnel"] }
]
```

Per-boot (one line, backgrounded, survives shell exit):

```bash
sudo tailscale funnel --bg 4000   # exposes :4000 as https://<host>.ts.net/
```

Confirm the public URL with `tailscale funnel status` (it prints the full HTTPS host) and wire it into `.env`:

```bash
PUBLIC_API_BASE=https://<host>.ts.net
# <vendor>_REDIRECT_BASE defaults to ${PUBLIC_API_BASE}/api/v1/<vendor> — leave unset unless the vendor needs a different path
```

Register the webhook URL with the vendor as `${PUBLIC_API_BASE}/api/v1/<vendor>/webhook`. Stop with `sudo tailscale funnel --bg off` when done. Caveats: Funnel is HTTPS-only on the public side (ports 443/8443/10000 externally) and forwards to any local port; first invocation prompts you to accept the serve ToS once per machine.

ngrok is the fallback (free URL changes on every restart, so the Zernio-side webhook registration goes stale — avoid unless Funnel's ACL step is blocked): `brew install ngrok && ngrok config add-authtoken <token> && ngrok http 4000`. $10/mo gets a reserved subdomain if you have to use it long-term.

**Restart EVERY process that loaded `.env` after you add or change the ingress URL** (API, worker-core, worker-render, `next dev`) — in-process dotenv is read once at startup, so a running API keeps sending the old redirect URI to the vendor. Covered in SKILL.md but worth re-stating here because it bites hardest on first ingress-wire-up: the vendor OAuth redirect fails with "redirect_uri mismatch" and the obvious guess is a typo in `.env`, when actually the API is just serving stale config.

## Purging test data (DB + object storage)

Use when the user wants e2e/test projects, renders and assets gone "including storage and DBs". Order matters; none of it needs a live render.

1. **Inspect, then ask once.** Tables live in schemas (`content.*`, `platform.*`, `billing.*`) — plain `\dt` shows nothing. Group projects by title/workspace (`select title,kind,count(*) ... group by 1,2`) and show the few that might be real; ask which survive. Also ask whether Series and Cast (`content.characters`) are in scope — they were created by tests too but Cast backs shared UI assets.
2. **Back up first, as the superuser.** `pg_dump -Fc` as the app role (`openstudio`) fails with `permission denied` on some tables; use `-U $USER` (the cluster superuser). Mirror buckets with `mc mirror local/<bucket> <scratch>/…` into the Hermes scratch dir (auto-pruned after ~24h, so tell the user the undo window). `mc alias` `local` already exists (`minioadmin`).
3. **Delete in one transaction, as superuser, with before/after counts.** `DELETE FROM content.series; … renders; … assets; … projects;` — children (scenes, scripts, captions, episodes, revisions, quality scores, external audio) go via `ON DELETE CASCADE` from projects/renders, but `content.series` and `renders→assets` are `NO ACTION`/`SET NULL`, so delete them explicitly and verify every child count is 0 in the AFTER select. Put it in a `.sql` file with `\set ON_ERROR_STOP on` and `BEGIN/COMMIT`.
4. **Before removing storage prefixes, find which prefixes live rows still reference** (`characters.avatar_url/sample_url`, `templates.preview_url`, presenter sprites). Delete only prefixes the deleted rows owned (`workspaces/`, `external/`, `stitched/`, `test/`, `tts/`, probe/e2e folders) with `mc rm -r --force --quiet local/<bucket>/<prefix>/`; leave shared catalog prefixes (`presenters/`, `templates/`, `cast-*`, and the demo workspace folder if its ids match live characters — verify with `comm -12`).
5. **Sweep the leftovers**: `redis-cli dbsize`, Temporal running-workflow count, `platform.outbox` rows for the deleted ids, and `billing.reservations` (old holds stay behind and point at deleted renders — report them, ask before touching billing).
6. **Verify through the app**, not just SQL: sign in via the browser and confirm the Library shows its empty state and Home shows the first-visit state.
7. Test suites that create "Live test project"-style rows will refill the DB if they run against it; say so.

## Signing in from the browser tool (UI verification)

- `/signin` sends a **6-digit code**, not a magic link. Read it from Mailpit's API (`GET localhost:8025/api/v1/messages?limit=1` → `/api/v1/message/<ID>`, regex `\b\d{6}\b`), focus the first `input[type=text]`, dispatch one `Input.dispatchKeyEvent` per digit, click `button[type=submit]`. Dev mailbox only — not a real credential.
- Sessions die between browser_exec calls (API restarts invalidate them; cookies also drop). Do sign-in AND the check in the SAME browser_exec call, and start every call with `js('location.href')` — if it says `/signin`, re-auth before trusting any DOM probe (a null `querySelector` on the sign-in page looks like a layout bug).
- No `workspace` variable inside browser_exec; write screenshots/refs to `~/.hermes/cache/scratch/`.

## Sticky elements inside the app shell

The shell's top bar is `sticky top-0 z-30` and **78px** tall; it publishes `--app-top` on the content column. Any page-level sticky aside must use `top-[calc(var(--app-top,0px)+1.5rem)]`, not `top-6`, or it slides under the bar. Phone tab bar is `fixed bottom-0 h-16 z-30` and already pads the safe area — page bars go at `bottom-16 z-20` with plain padding. A sticky card taller than `viewport − 102px` cannot pin (looks like "stickiness is gone" on short windows) — cap it with `max-h-[calc(100vh-var(--app-top)-3rem)] overflow-y-auto`.

## Server menu ↔ web fixture pattern

When the Go API owns a menu the web renders (influencer traits), keep ONE fixture: a Go test marshals the menu and compares to `apps/web/lib/<name>.fixture.json` (`UPDATE_FIXTURES=1 go test ./apps/api -run TestInfluencerMenuMatchesWebFixture` regenerates); web tests and Storybook import that JSON. Unexported Go fields (prompt phrases) never reach it.

## apps/web test gotchas

- vite 8's oxc transformer ignores plugin-react's esbuild `jsx: automatic`; `vitest.config.ts` needs `oxc: { jsx: { runtime: "automatic" } }` or every `.test.tsx` fails with "make sure to not set jsx to preserve". Already applied; don't remove it.
- Storybook `main.ts` scans `components/**`, `app/**`, `stories/**`. A non-story named export in a `.stories.tsx` (e.g. a fixture) becomes a phantom story — move fixtures to a sibling module.
