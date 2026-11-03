# Dev stack — boot, verify, teardown

One-shot recipe for bringing OpenStudio up locally and confirming every surface is healthy. Read with the `openstudio-development` SKILL.md's invariants (money is integers, no SQL outside `services/db`, non-technical web UI, etc.) still in force.

## Native-only policy

This VM cannot run Docker Desktop or OrbStack (GUI first-run fails headless). Everything below is Homebrew-native via `scripts/dev-native/*`. Do not reach for `docker compose` for infra on this machine; `compose.yaml` is for CI / cloud only.

## Boot order

Infra first, then app processes. Scheduler + worker-core are usually already running from a prior boot — check `pgrep -fl 'apps/scheduler|worker-core'` before launching duplicates.

```bash
cd /Users/sa-vm/Workspace/openstudio/openstudio

# 1. Infra (idempotent — safe to re-run; prints `already up` for live services).
./scripts/dev-native/up.sh

# 2. Load env for all app processes.
set -a && source .env && set +a

# 3. App processes — each in its own backgrounded shell with its own log.
mkdir -p scripts/dev-native/state/logs
nohup go run ./apps/api                               > scripts/dev-native/state/logs/api.log                 2>&1 &
nohup go run ./apps/worker-core                       > scripts/dev-native/state/logs/worker-core.log         2>&1 &
nohup go run ./apps/scheduler                         > scripts/dev-native/state/logs/scheduler.log           2>&1 &
nohup go run ./apps/worker-render/cinematic-renderer  > scripts/dev-native/state/logs/cinematic-renderer.log  2>&1 &
( cd apps/worker-render/motion-renderer && nohup pnpm dev > ../../../scripts/dev-native/state/logs/motion-renderer.log 2>&1 & )
( cd apps/web                       && nohup pnpm dev     > ../../scripts/dev-native/state/logs/web.log              2>&1 & )
```

`apps/worker-render/` is a GROUP folder (workspace glob `apps/worker-render/*`): the motion renderer (Node/Remotion, queue `render`) and the cinematic renderer (Go, queue `cinematic`) are separate processes that BOTH must be running — the Temporal workflow routes to one or the other by kind, and the sibling errors with `cinematic renders must dispatch to the 'cinematic' Temporal queue` if its worker is absent. Launching only motion-renderer leaves cinematic renders stuck forever.

```bash
# (end of app launch block)
```

`go run` compiles on each boot (~15–25s before `:4000` listens); don't health-check for 25s or you'll trip the "API down" alarm during a normal cold start.

**Under Hermes, launch each app process with its own `terminal(background=true)` call, not `nohup ... &` in a foreground command.** The terminal tool refuses shell-level background wrappers (`nohup`, `disown`, `setsid`, trailing `&`) so Hermes can track the PID; the recipe's `nohup ... > log 2>&1 &` block comes back with `Foreground command uses shell-level background wrappers`. Translate each launch line to its own call: `terminal(command="cd <dir> && set -a && source .env && set +a && exec go run ./apps/<svc> > <log> 2>&1", background=true)`. Use `exec` so the tracked PID is the Go/Node process itself, not a shell wrapper. Readiness checks + the healthz sweep stay in separate foreground calls after a `sleep 35`.

**`scripts/dev-native/up.sh` prints `namespace=openstudio` in its "stack is up" summary — ignore it.** The dev server's real namespace is `default` (SKILL.md invariant); `TEMPORAL_NAMESPACE=default` in `.env` is authoritative. Do not re-point workers at `openstudio` based on up.sh's banner.

## Verify everything is up

```bash
for s in "api :4000/healthz" "worker-core :4100/healthz" "motion-renderer :4101/healthz" "cinematic-renderer :4102/healthz" "web :3001" "temporal-ui :8233" "mailpit :8025" "minio :9000/minio/health/live"; do
  name=${s%% *}; url=${s##* }
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost${url}")
  printf "  %-16s %s → %s\n" "$name" "$url" "$code"
done
```

Expected: 200 across the board (except Temporal gRPC :7233 which returns 000 to HTTP — probe it with `grpcurl` or just by starting worker-core).

## Port map (local)

| Service | Port | Notes |
|---|---|---|
| api | 4000 | `/healthz` returns `{ok:true,service:"api"}` |
| worker-core health | 4100 | override via `WORKER_CORE_HEALTH_ADDR`; empty disables |
| motion-renderer health | 4101 | override via `WORKER_RENDER_HEALTH_ADDR`; empty disables |
| cinematic-renderer health | 4102 | override via `WORKER_RENDER_HEALTH_ADDR`; empty disables |
| scheduler health | — | off by default; set `SCHEDULER_HEALTH_ADDR` to enable |
| web (Next 15) | 3001 | `apps/web/package.json` pins `next dev --turbo -p 3001`; not a fallthrough from :3000 |
| temporal gRPC | 7233 | dev-server namespace is `default` (NOT `openstudio` despite the `--namespace openstudio` flag — up.sh hint-prints the wrong namespace; `TEMPORAL_NAMESPACE=default` in `.env` is authoritative) |
| temporal UI | 8233 | |
| postgres | 5432 | db=`openstudio`, user=`openstudio` (no pw), superuser=`sa-vm` |
| redis | 6379 | |
| minio API | 9000 | creds `minioadmin/minioadmin` |
| minio console | 9002 | root is 403; login path works |
| mailpit SMTP | 1025 | UI :8025 |
| llama.cpp (Qwen2.5-3B) | 8080 | started by `scripts/dev-native/llamacpp.sh` |
| otelcol (OTLP gRPC/HTTP) | 9091 / 9092 | **not the default :4317/:4318** — see OTel pitfall |
| prometheus / loki / tempo / pyroscope | 9050 / 9060 / 9070 / 9080 | started by `scripts/dev-native/obs/*` |

## Pitfalls

- **Web binds :3001 by design, not by fallthrough — `apps/web/package.json`'s `dev` script hard-codes `next dev --turbo -p 3001`.** Health-check `:3001`, not `:3000`; editing a `WEB_PORT` env or hoping Next falls through from :3000 won't move it. Change the port by editing the `dev` script, not by killing whatever holds :3000.
- **`pkill -f 'apps/api|apps/scheduler|apps/worker-core'` misses the renderers.** The group folder splits into two sibling binaries — add `apps/worker-render/cinematic-renderer` to the teardown pattern and `pkill -f 'motion-renderer|next-server|next dev'` for the Node side; a renderer left running after `down.sh` steals tasks from the next session and renders flap.
- **OTel exporters in `apps/web` and `apps/worker-render` default to `:4318` but the local otelcol listens on `:9091` (gRPC) / `:9092` (HTTP) — spans and metrics are dropped with `ECONNREFUSED` noise.** Not fatal; fix by exporting `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:9092` (or the gRPC equivalent) in `.env` before boot, or ignore if you don't need traces this session. Do NOT "fix" by killing the exporter — that masks real outages later.
- **Temporal dev server wedges after long uptime; the CLI hangs instead of reporting.** If `temporal operator namespace describe openstudio` or any worker's gRPC call hangs, bounce temporal via `scripts/dev-native/down.sh` → `up.sh` before debugging anything else.
- **Scheduler + worker-core are often still running from a previous session.** `pgrep -fl 'apps/(scheduler|worker-core)'` first; don't launch duplicates or they fight for the same Temporal task queue slots and renders flap.
- **`go run` recompiles every boot.** The first `/healthz` 200 is 15–25s after launch, longer on a cold module cache. Not an outage.
- **`services/db/migrations/` numbering: check `ls services/db/migrations/ | tail -1` for the next number** — do not assume. Numbering starts at `00001` not `00000` (goose convention here).
- **`NODE_ENV=production` exported in the operator shell silently flips every Go service to prod defaults.** `services/config/config.go` reads `NODE_ENV` and sets `prod := env == "production"`, which gates many `getenvBool(FLAG, !prod)` defaults off. godotenv does NOT override pre-set env vars, so `NODE_ENV=development` in `.env` cannot rescue a shell that already has it. Symptoms: features default-on in dev return `false` from the api, dev-only logging goes quiet, prod-only requireds blow up at boot. Diagnose with `ps eww -p <pid> | tr ' ' '\n' | grep NODE_ENV`; fix by launching with `env -u NODE_ENV go run ./apps/<svc>` or `unset NODE_ENV` in the login shell. Scrub it from `~/.zshrc` / `~/.bashrc` once; a leftover export from a Node project will haunt every Go boot afterward.
- **When removing/renaming a feature flag, update `apps/web/public/openapi.yaml` as well as `docs/openapi/openstudio.yaml`.** The public mirror is a plain file copy (not a symlink); `cp docs/openapi/openstudio.yaml apps/web/public/openapi.yaml` after editing the source, or the dev-tools page serves a stale spec. Audit touchpoints when retiring a flag: `services/config/config.go` (struct field + env read), every `s.cfg.<Flag>` guard in `apps/api/`, any `features["<flag>"]` emission in `/me` surfaces, the regression test that asserted the 503, the web page type/filter + `serverFetch` for `/internal/me`, README, feature doc, rollout doc, and both OpenAPI copies. `grep -rln <FlagStructField>\|<FLAG_ENV>\|<flag_json_key>` catches them in one pass.

## Teardown

```bash
# App processes — kill by pattern, not pid (go run spawns a child).
pkill -f 'apps/api|apps/scheduler|apps/worker-core|apps/worker-render/cinematic-renderer' || true
pkill -f 'motion-renderer|next-server|next dev'                                           || true

# Infra.
./scripts/dev-native/down.sh
```

`down.sh` leaves `~/.openstudio/obs/` on disk; blow that away only if you want to reset Grafana dashboards + Prometheus TSDB.

## Where logs go

- App processes: `scripts/dev-native/state/logs/{api,worker-core,scheduler,cinematic-renderer,motion-renderer,web}.log`
- Infra (minio, mailpit, postgres, temporal, redis): `scripts/dev-native/state/logs/*.log` (whatever `up.sh` prints)
- Observability stack (tempo/loki/prom/otelcol/pyroscope): `~/.openstudio/obs/<service>/*`
