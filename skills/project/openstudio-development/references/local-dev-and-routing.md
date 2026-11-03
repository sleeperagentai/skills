# Local dev, routing, and env (api / worker / web)

Operational rules for booting and debugging the OpenStudio dev stack. SKILL.md has the high-level stack sentence; this file is the day-to-day workflow.

## `scripts/dev-native/up.sh` boots infra only

- Covers postgres, redis, minio, temporal, mailpit, and (with `--obs`) the Grafana / Prometheus / Loki / Tempo / Pyroscope / otelcol stack.
- Does NOT boot the six application services: `apps/api`, `apps/worker-core`, `apps/scheduler`, `apps/worker-render/cinematic-renderer`, `apps/worker-render/motion-renderer`, `apps/web`.
- `scripts/dev-native/down.sh` does NOT stop the app services either — kill them by PID or `lsof -i :<port> -t | xargs kill`.
- Convention: write app-service logs to `scripts/dev-native/state/logs/<name>.log` so a future session finds them next to the infra logs.

## Starting the app services

```
cd /Users/sa-vm/Workspace/openstudio/openstudio
env -u NODE_ENV go run ./apps/api                                           # :4000
env -u NODE_ENV go run ./apps/worker-core                                   # health :4100
env -u NODE_ENV go run ./apps/scheduler
env -u NODE_ENV go run ./apps/worker-render/cinematic-renderer              # health :4102, queue cinematic
( cd apps/worker-render/motion-renderer && pnpm dev )                       # health :4101, queue render
( cd apps/web && pnpm dev )                                                 # :3001
```

Always go through `env -u NODE_ENV` or scrub `NODE_ENV` from your shell rc. The reason is in the next section.

## `NODE_ENV=production` silently flips Go-service defaults

`services/config/config.go`:

```go
env := getenv("NODE_ENV", "development")
prod := env == "production"
...
SomeFeature: getenvBool("SOME_FEATURE", !prod),
```

- godotenv does NOT override pre-set env. Writing `NODE_ENV=development` in `.env` is a no-op if the shell already exported `production`.
- Every `getenvBool(KEY, !prod)` default silently flips. Symptom: dev defaults look wrong, feature flags default off in dev, `/me` reports features the user did not toggle off.
- Diagnose with `ps eww -p <pid> | tr ' ' '\n' | grep -E 'NODE_ENV|APP_ENV'`. The api child process (not the `go run` parent) is the one to inspect — `go run` compiles to a cached binary that inherits the parent env.
- Fix at source: scrub `NODE_ENV` from `~/.zshrc` / `~/.bashrc`. For a one-off boot use `env -u NODE_ENV go run ./apps/<name>`.

## Dev-login (session cookies without the web UI)

`.env` must have BOTH before the api boots:

```
AUTH_DEV_LOGIN=1
DEV_SEED_EMAIL=you@example.dev
```

Env is read once at startup; editing `.env` after the fact requires a restart. The handler is at `apps/api/auth_handlers.go:handleDevLogin` and `http.NotFound`s when `AUTH_DEV_LOGIN != "1"` OR `env == "production"`.

Mint a cookie:

```
curl -sS -c /tmp/cookies.txt -X POST http://localhost:4000/auth/dev/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.dev"}'
```

Subsequent probes:

```
curl -sS -b /tmp/cookies.txt http://localhost:4000/internal/me
```

## Kind registry drives render routing

`apps/api/main.go` has a registry slice inside the state constructor:

```go
registry := []struct {
    id, route, composition, category string
    enabled                          bool
}{
    {"motion-graphics", "motion-graphics", "MotionGraphics", "creations", cfg.KindMotionGraphicsEnabled},
    {"cinematic",       "cinematic",       "",               "video",     cfg.KindCinematicEnabled},
    // add the new kind HERE
}
```

The loop below `for route, kindID := range st.kindByRoute` is what mounts, per kind:

- `POST /api/v1/{route}/projects` (create)
- `POST /api/v1/{route}/projects/draft`
- `PATCH /api/v1/{route}/projects/{id}/progress`
- `POST /api/v1/{route}/projects/{id}/render` — dispatches to `handleRenderProject(w, req, kindID)`

**A kind with handlers, settings parsing, migrations, and a web wizard will still 404 on `/render` until the slice entry lands.** `composition=""` means the kind renders on a non-Remotion Temporal queue (cinematic → cinematic-renderer); a Remotion kind sets the composition name from `packages/compositions/src/Root.tsx`.

## Kind URL convention: no `/kinds/` prefix

Mirror the existing kinds:

```
POST /api/v1/motion-graphics/projects/{id}/render
POST /api/v1/cinematic/projects/{id}/render
POST /api/v1/captioned-clip/projects/{id}/render
```

A client that inlines `/api/v1/kinds/{route}/projects/{id}/render` 404s even with the kind registered correctly. The `/kinds/` segment only exists on `/api/v1/kinds/registry` (the listing endpoint).

## Captioned-clip has a split upload path

Unlike other kinds, uploads do NOT go through `/{route}/projects` — they POST to `/api/v1/caption/upload` (multipart) and `/api/v1/live/caption/upload`. Only the render step uses the kind-route convention above. If you add captioned-clip to the kind registry (required for `/render`), the auto-registered `/projects` and `/projects/draft` routes are harmless because nothing calls them.
