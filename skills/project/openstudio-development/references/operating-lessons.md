# Operating lessons

Standalone rules moved out of SKILL.md (size limit). Each is an imperative + why.

**When the user says "done" for an out-of-band config step (env var, third-party dashboard, provider top-up), they did SOMETHING — not necessarily the right thing.** External-provider integrations produce a rotating set of failure modes that all look similar from the operator's chair: 401 wrong key, 402 wrong voice tier, 404 wrong model id, 429 quota. Each looks like "provider rejected the request" but each has a different fix, and the operator can move from one to the next without realising. Never conclude "they fixed it" from a `stat` on `.env` (file grew, mtime changed) — issue the actual API call whose failure was the trigger, read the raw provider response in the log, and only claim resolution when THAT specific error is gone.

## Boot the full stack for an E2E

```bash
cd /Users/sa-vm/Workspace/openstudio/openstudio
scripts/dev-native/up.sh

cat > /tmp/os-env.sh <<'EOF'
export DATABASE_URL='postgres://openstudio@localhost:5432/openstudio?sslmode=disable'
export S3_ENDPOINT=http://localhost:9000
export S3_ACCESS_KEY=minioadmin S3_SECRET_KEY=minioadmin
export S3_BUCKET_PUBLIC=openstudio-public S3_BUCKET_PRIVATE=openstudio-private
export MEDIA_PUBLIC_URL=http://localhost:9000/openstudio-public
export TEMPORAL_ADDR=localhost:7233 TEMPORAL_NAMESPACE=default
export AUTH_SESSION_SECRET=$(openssl rand -hex 32)
export API_KEY_HMAC_SECRET=$(openssl rand -hex 32)
export WEBHOOK_HMAC_SECRET=$(openssl rand -hex 32)
export AI_PROVIDER_MODE=fake
EOF

source /tmp/os-env.sh
mkdir -p /tmp/os-logs
```

Then launch each long-running process through the Hermes terminal tool with `background=true` — one call per process, with `notify=["listening", "ready", "error"]` or similar watch patterns. The four processes are:

- `go run ./apps/api` (redirect stdout/stderr to `/tmp/os-logs/api.log`)
- `go run ./apps/worker-core` → `/tmp/os-logs/worker-core.log`
- `cd apps/worker-render && pnpm dev` → `/tmp/os-logs/worker-render.log`
- `cd apps/web && pnpm dev` → `/tmp/os-logs/web.log`

**Never wrap these in `nohup ... &`, `disown`, or `setsid` inside a foreground `terminal()` call — the tool refuses shell-level backgrounding with a hard error ("Foreground command uses shell-level background wrappers...") and the process never starts.** Use the tool's own `background=true` so Hermes tracks the pid and readiness watchers work. For Node processes, `set -a; . ./.env; set +a` inside the same call before `pnpm dev` so the shell exports `.env` (in-process dotenv still runs, this belt-and-braces gets PATH/brew prefix into pnpm).

Health check (separate foreground call after readiness): `curl -sf http://localhost:4000/healthz` returns `{"ok":true,...}`.

Readiness signals to grep in the logs (or set as `notify` patterns) once processes are up:
- api: `"msg":"api listening"` + all `aigw: <Cap>=<source>` lines emitted
- worker-core: `Started Worker Namespace default TaskQueue pipeline`
- worker-render: `worker ready` AND `state: 'RUNNING'` on queue `render` in namespace `default` (not `openstudio` — see invariant above)
- web: `Ready in <N>ms` (Next dev picks port 3001 if 3000 is taken; grep for `Local:` to get the actual port)

**Worker/API restart hygiene: kill the compiled child, not the `go run` wrapper.** Each `go run ./apps/<x>` forks a build-cached binary (`…/go-build…/exe/<x>`) that `pkill -f 'go run …'` and `pkill -f 'apps/<x>'` do NOT reliably match; the child keeps its listen socket (API) or its Temporal poll (worker) and serves OLD code — stale workers burn provider quota on retry loops, and a stale API once accepted a payload the fix refuses and submitted a real portrait job. Procedure, in order: `pkill -f 'exe/<x>'` (plus `pkill -f 'next dev'` for web), confirm `lsof -nP -iTCP:<port> -sTCP:LISTEN` is empty, relaunch via `go build -o /tmp/os-<x> ./apps/<x> && /tmp/os-<x>` so the PID is unambiguous, and before any call that can spend compare `ps -o lstart -p $(pgrep -f os-<x>)` with `git log -1 --format=%ci`. Symptom when skipped: `api listening` then `bind: address already in use`, and the old process keeps answering. Full procedure and the post-incident clean-up live in `references/dev-services-and-ports.md`.

**Scope the pkill pattern to ONE process — pattern-broad kills take out the whole dev stack.** `pkill -f 'apps/api'` and `pkill -f 'go run'` match every sibling worker (`go run ./apps/worker-core`, `go run ./apps/scheduler`, `go run ./apps/worker-render/cinematic-renderer`) because their argv all contain `apps/` and `go run`. Losing those while the API restarts leaves the api up but the Temporal workflow it just dispatched sitting on an unpolled queue, and the user's next click looks like a hung render even though the api is fine. Prefer, in order: (a) kill by exact PID from the Hermes backgrounded session (`terminal` returns `pid`; store it), (b) `lsof -ti:<port> \| xargs kill` to target a listener (api only), (c) `pkill -f 'exe/<name>$'` with a `$` anchor so the compiled-binary match cannot stretch. After any restart that touched the stack, re-check `pgrep -fl 'exe/worker-core\|exe/scheduler\|motion-renderer\|cinematic-renderer\|next-server'` returns the full set — a missing worker is why the next render hangs at 0% with no error in the api log.

**Admin-merge mechanical PRs the moment local verification passes — do not watch the CI minute-counter tick for pure-doc / pure-rename / small-UI-copy / lockfile diffs (standing user preference).** For PRs whose diff is behaviour-neutral and locally verifiable (biome green + typecheck green + `go test` where relevant), `gh pr merge <N> --squash --delete-branch --admin` after a brief smoke of CI (one `gh pr checks <N>` call to see jobs queued, not polled to completion). For PRs that change behaviour — new handler, migration, non-trivial Go logic, UI data-flow — let CI finish (`gh pr checks <N> --watch`) before merging. The signal from the user is explicit: `skip wait for green ci - merge and continue to <next>` and `merge pr and proceed to <next>`. Watching 7 minutes of green CI for a job-label rename is the user's frustration surface, not a safety measure. The exception is any PR that touches the CI workflow files themselves — one green run on the PR branch is the only proof the workflow still runs at all, so watch it through.

**Hermes holds compound shell commands for approval when any segment looks destructive; a timeout is a refusal, not a pass.** `go mod tidy && … && git commit && git push` chained in one call blocked on the user and nothing ran. Keep builds/tests, `git add` of an explicit file list, `git commit` and `git push` as SEPARATE terminal calls — each then runs without a gate and a failure is attributable to one step.

**Before `git add -A` (or `git add <dir>`) in the parent, read `git status --short` for files you did not create.** The user drops notes and PRDs (`docs/prd/*.md`) into the tree while you work; sweeping them into a feature commit publishes their drafts under your message. Stage the explicit paths you touched. The same rule for subagents is in SKILL.md.

## API key extraction (visual-truncation trap)

The api seed prints `OPENSTUDIO_API_KEY=sk_live_<48hex>` to stdout. Terminal capture may render this visually as `sk_liv...e972` (looks masked) — the full key is still in the log file. Always grep the file, never trust the visible short form:

```bash
grep -oE 'sk_live_[a-f0-9]+' /tmp/os-logs/api.log | head -1 > /tmp/os-key.txt
# Then: -H "Authorization: Bearer $(cat /tmp/os-key.txt)"
```

## Route shape — kind-scoped, not generic

**Every creation belongs to a project — see `references/project-as-creation-root.md`**. Render status, the in-flight edit lock, draft/render list views and presigned-URL persistence are in `references/render-lifecycle.md`. **Run the Go suite as `go test ./apps/... ./services/...` from each module dir, or enumerate packages — a single module-path glob (`go test github.com/agentclip/openstudio/services/...`) resolves through `go.work` and SILENTLY OMITS sibling modules, reporting green while a package it never ran is broken.** before touching stage handlers, `stageGuard`, the wizard, or any migration under `content.*`. Headlines: `content.scripts`/`external_audio`/`assets`/`quality_scores` are all NOT NULL on `project_id` (migration 00025); `stageGuard` verifies ownership before moderation and returns 404 (never 403) for another tenant's project; the wizard creates the project at step 1 via `POST /{kind}/projects/draft` (idempotent per `sessionKey`) and resumes from `/projects/{id}/create`; settings merges must descend one level; and `"use client"` on a pure-function module 500s the server-rendered resume page.

Projects and renders live under the kind's `routeSegment`. `POST /api/v1/projects` returns 405. Correct shape:

- `POST /api/v1/{routeSegment}/projects` — body `{title, scenes:[...]}` (NOT `{name, kind}`)
- `POST /api/v1/{routeSegment}/projects/{id}/render` — `{}` body is valid
- `GET  /api/v1/renders/{id}` — poll here; `stage:"done"` + `outputUrl:"http://..."` means finished
- `GET  /api/v1/kinds` — returns a BARE ARRAY of `{id, routeSegment, composition, category, enabled}`, not `{all:[...]}`

`routeSegment` lives in the kind registry in `apps/api/main.go`; grep there before assuming the URL.

**One concept, two create handlers — check WHICH one the client hits before adding a field.** The kind-route loop in `main.go` branches: `motion-graphics` goes to `handleCreateMotionGraphicsProject`, every other kind to the generic `handleCreateProject`. A field added to the generic handler is silently dropped for motion-graphics — the request still returns 201, so nothing errors and the feature looks shipped. Grep the route registration for the kind you are targeting (`rg -n 'Post\(fmt.Sprintf\("/%s/projects' apps/api/main.go`) and add the field to the handler that is actually wired, or register one handler for both.

**`SetProjectSettings` REPLACES the whole `settings` JSONB blob — merge, and merge ONE LEVEL DEEP.** `handleCreateMotionGraphicsProject` writes its `motionGraphics` payload with a second call *after* the row is created, so anything the create itself stored is discarded. Symptom: create returns 201 with a correct-looking response body and the column comes back missing the field you just wrote.

A top-level merge then fails the same way one level down, which is the harder version to spot: `settings` is a flat map of namespaces (`{wizard:{…}, motionGraphics:{…}}`) whose values are themselves objects, so a patch carrying `{"wizard":{"lookId":…}}` replaces the entire `wizard` blob and discards the voices saved at create. Merge the nested objects too — but stop at ONE level and replace arrays wholesale, or a patch can never CLEAR a nested field (shortening `voiceIds` becomes impossible once every absent key means "keep"). Assert the value is PERSISTED (`psql -c 'SELECT settings FROM content.projects WHERE id=...'`) rather than trusting the status code; a status-code assertion passes through both bugs.

**Namespaces a CLIENT may write need a server-owned exclusion list.** The wizard's idempotency key lives in the same blob the client PATCHes, so a merge that accepts it verbatim lets one wizard session point its key at another session's project. Re-assert server-owned keys from the existing row after merging, never from the request.

**`content.projects.settings` was write-only until deliberately wired — check the HTTP response too, not just the store.** `CreateProject` hardcoded `'{}'` and `GetProject` never selected the column. Both were fixed, and the column was still invisible to the frontend because `handleGetProject` did not include it in its response map: a store that reads the column and a handler that drops it look identical from the DB side. When a value must survive request→request (an approved audio key, a resolved voice, saved wizard progress), confirm the write, the store read, AND the handler's response body.

## Adding a new kind — the 6 wire points

A kind is not "added" until ALL of these carry it, or `/api/v1/kinds` won't surface it and pricing silently falls back:

1. `apps/api/main.go` — kind registry struct literal `{id, route, composition, category, enabled}`
2. `apps/api/content.go` — `kindDisplayName` map + `kindTagline` map (add to `kindDefaultCaptions`/`kindAvgSeconds` switches if defaults don't fit)
3. `services/pricing/pricing.go` — `Kind` const AND entry in `baseByKind`
4. `packages/schemas/src/index.ts` (or `packages/schemas/src/kinds/`) — Zod input schema
5. `packages/compositions/src/Root.tsx` (register) + `packages/compositions/src/compositions/<Name>.tsx` + `packages/compositions/src/render-input/`
6. `apps/worker-render/src/activities/renderRemotion.ts` — `kind → compositionId` router case

If the kind calls external APIs, add a Temporal activity in `apps/worker-core/activities/` and branch before `RenderInlineActivity`. Vendor-rendered kinds: `references/vendor-rendered-kinds.md`.

## Ship verification — click-through before declaring done

Unit tests and subagent summaries do NOT prove a user-visible feature works. Three failure modes recur:

1. **URL mismatch between UI and API.** The frontend builds its own URLs, so a path the API never registered is a 404 that no Go test can catch. Seen on the render path (`/api/v1/projects/{id}/render` posted while the route is `/api/v1/{routeSegment}/projects/{id}/render`) and on auth (the sign-in form posting `/auth/start` + `/auth/verify` while the API served `/auth/otp/request` + `/auth/otp/verify`) — the auth case meant sign-in had never worked end to end. Do not spot-check one endpoint: sweep the whole surface. Extract every literal path the frontend sends and curl each one against the running API:

```bash
rg -oN --no-filename "apiFetch\\(\"[^\"]+|fetch\\(\"/(api|auth|internal)[^\"]+" apps/web/app apps/web/components apps/web/lib \\
  | grep -oE '/(api|auth|internal)[^\"]*' | sort -u
```

Then `curl -s -o /dev/null -w '%{http_code} %{url_effective}\\n'` each. A 404 or 405 here is a dead feature regardless of what the UI shows. When a client path is already shipped and you are fixing the server, prefer registering the client's path as an alias to the canonical handler over renaming the client — aliases keep existing callers working while the canonical name stays the one documented. Do not assume the plan's PRD-written path is the one shipped.
2. **Fake-provider content reaches users.** With `AI_PROVIDER_MODE=fake` the LLM echoes the prompt back verbatim with a `[fake:textgen h=<hash>]` marker; the fake TTS returns placeholder bytes. Anything scripted, transcribed, or narrated by fake providers is developer output, not user content — sanitise on the API side (see `parseScriptOutput` in `apps/api/content.go`: `looksLikePromptEcho` + `synthNarration`) or gate the feature behind real provider keys.
3. **Wizard renders from hardcoded `FALLBACK_*` arrays and never calls the API.** Wizard files under `apps/web/app/(app)/create/*/wizard.tsx` ship with opinionated defaults (SVG-face presenters like `presenter_scholar`, seed voice lists) that render fine on their own. A wizard step can be "working" in the browser while zero data flows through `/api/v1/presenters` or `/api/v1/live/voices` — and worse, its dispatched action payloads carry the fake IDs into `POST /projects`. Grep every wizard step file for both the `FALLBACK_` constant AND an `apiFetch` on the corresponding endpoint; if only the constant exists, the API path was never wired. See `references/web-app-nextjs.md` for the audit pattern.

**A plan's STATUS table is not verification — grep the invariant across every call site before claiming a phase is done.** Multi-phase plan docs (`.hermes/plans/*.md`, `docs/plans/*.md`) carry a STATUS table marking phases ✅/🟡/⬜ and prose like `5.2 cookie hardening ✅ in code`. Treat those marks as a reading hypothesis, not evidence — self-reports age the moment a sibling handler ships. Before reporting phase/task done to the user, grep for the actual guards the task required across every site, not just the one PR that moved status to ✅. Examples: for a cookie-hardening phase, `rg 'HttpOnly|SameSite|Secure:' --include='*.go'` and read each mint site — a gate conditioned on `APP_ENV == "production"` while the plan specified "HTTPS origin" is a divergence; a second un-plan-noted handler minting the same cookie with no `Secure` flag is a dead-code-shaped bug (see dead-handler rule below). For a moderation phase, grep every `/live/*` and generative handler for the moderation call before the LLM invocation. The user's `is X actually done?` follow-up is the signal you took the plan at its word — audit the whole surface, not the headline PR.

**Before hardening a code path, grep for callers — if zero, delete instead.** Dead-but-live handlers (routes still mounted, docs saying "kept for CLI back-compat", session writes with hardcoded `usr_demo`/`ws_demo`) tempt a small "just fix the cookie flags / add the Secure flag" patch because the diff looks surgical. That ships hardened dead code: the demo artefact survives, the route still mints real sessions, the next audit finds the same problem under a slightly different flag. One grep across the repo decides it: `rg -n '<route>|<handlerName>' --include='*.go' --include='*.ts' --include='*.tsx' --include='*.py' --include='*.sh' .` excluding `docs/` and `openapi/`. Zero hits → the correct patch is remove the handler + the route mount + OpenAPI path defs + public-surface doc rows + any now-unused imports (`crypto/sha256` is the common one), not harden. Also delete the OpenAPI `$ref` entry in `docs/openapi/openstudio.yaml` AND the standalone path def in `docs/openapi/auth.yaml` (or whichever module file holds it) — redocly lint catches orphans but not stale deprecated-but-still-defined paths.

**A new regression test must be proven to fail against the bug it guards.** A test written after the fix passes trivially — it may assert nothing, match the wrong string, or skip silently (a `t.Skipf` on an unreadable fixture path looks identical to a pass in the summary line). Before trusting a guard, reintroduce the defect, run the test, confirm it fails with the message you expect, then restore. For config-file guards keep a known-good copy first (`cp next.config.js /tmp/next.config.js.good`) so the restore is exact rather than hand-edited back.

**Confirm a failing build or test is pre-existing before attributing it to your change — or absolving yourself of it.** Check out HEAD into a throwaway worktree, symlink `node_modules` from the main checkout so the install cost is zero, and run the same command there:

```bash
git worktree add /tmp/os-baseline HEAD
ln -s "$PWD/apps/web/node_modules" /tmp/os-baseline/apps/web/node_modules
ln -s "$PWD/node_modules"          /tmp/os-baseline/node_modules
(cd /tmp/os-baseline/apps/web && npx next build 2>&1 | tail -12)
rm -f /tmp/os-baseline/apps/web/node_modules /tmp/os-baseline/node_modules
git worktree remove /tmp/os-baseline --force
```

Identical failure at HEAD = pre-existing; say so explicitly in the summary and commit message instead of either hiding it or claiming to have caused it. Prefer this over `git stash` for baseline checks: stash round-trips with untracked files silently drop or duplicate newly added files, and a stash taken mid-review can leave the tree in a state that needs rescuing.

After any wire-point change, verify with a real render — `go test` alone hides broken kind→composition routing:

```bash
API=$(cat /tmp/os-key.txt)
curl -sS -X POST -H "Authorization: Bearer $API" -H "Content-Type: application/json" \
  -H "Idempotency-Key: e2e-$(date +%s)" \
  http://localhost:4000/api/v1/voiceover/projects \
  -d '{"title":"E2E","scenes":[{"text":"hello","durationSec":6}]}'
# POST /projects/{id}/render, poll GET /renders/{id} until stage==done,
# curl the outputUrl, then ffprobe for real 1080x1920 H.264:
ffprobe -hide_banner -loglevel error \
  -show_entries 'stream=codec_name,codec_type,width,height,duration' /tmp/e2e.mp4
```

## TTS duration probing (ffprobe fallback)

Provider TTS adapters vary on whether they report `DurationMs`. ElevenLabs' HTTP endpoint returns MP3 bytes with no duration field — the adapter hardcodes `DurationMs: 0`. Downstream stages (caption timing, MG turn Sequence lengths, S3 object metadata) all depend on knowing the real duration. Every TTS call site MUST fall through: adapter-reported `DurationMs` → ffprobe probe of the audio bytes → word-count estimate. `ffprobe` is installed by `scripts/dev-native/up.sh`'s Homebrew set, so it's always on PATH in dev:

```go
cmd := exec.CommandContext(ctx, "ffprobe",
    "-v", "error",
    "-show_entries", "format=duration",
    "-of", "default=noprint_wrappers=1:nokey=1",
    "pipe:0")
cmd.Stdin = bytes.NewReader(audio)
out, err := cmd.Output()
// parse `strconv.ParseFloat(strings.TrimSpace(string(out)), 64) * 1000` → ms
```

Estimate fallback: `len(strings.Fields(text)) * 180` ms per word matches natural narration pace. BOTH the API-side `synthesiseOne` in `apps/api/live_tts.go` AND `apps/worker-core/activities/tts.go` need this — the API path handles voice previews / one-shot TTS while the activity handles render-pipeline TTS. Fix them together, or one path ships silent 0-duration audio while the other works.

## Mid-feature cancel means rolling back the migration, not just the files

When the user stops a half-built feature with "do not do X at all" / "stop" / "roll back", the cleanup covers THREE layers, not one:

1. `goose -dir services/db/migrations postgres "$DATABASE_URL" down` for every applied migration in the aborted branch. The schema change is the stickiest artefact — leaving it means the next feature starts on a DB shape that disagrees with main.
2. `rm -f` the uncommitted scratch files (plan docs, store methods, handlers, migrations). Verify with `git status --short` filtered to exclude pre-existing-dirty files you must not touch.
3. `git checkout -- <file>` for files you partially edited that WERE on main (config.go gaining a new field is the common one; the add is reverted together with the migration).

Stopping at step 2 is the trap: the local DB sits one version ahead of every other dev's and ahead of main, and the next migration you write collides on its number or runs against a schema that still has the dropped feature's tables. Verify the final state with `goose status | tail -3` matching `main`'s expected version.

Mentioning the DB rollback in your reply after the cleanup is also what tells the user you did the full job — "files reverted" alone sounds like dead scaffolding is still on their database.

## Volume justifies complexity, not the other way around

For an escape-hatch feature (manual account recovery, operator-only unlock, dead-letter replay, break-glass admin UI), ask the user what the current volume is before scaffolding the self-serve path. A SQL runbook that an on-call engineer runs ~once a quarter is often the correct TERMINAL state, not a placeholder. Signals that the pretty UI is premature:

- The feature's inputs are inherently judgement calls (identity verification, suspected fraud) that need a human approver whose click just encodes the SQL the runbook already contains.
- The expected request rate is less than one per week in production.
- A manual runbook already exists and no one has reported pain running it.

When those hold, propose shipping the runbook polish (clearer SQL template, named audit-event kind for the manual action, a single ADR line) instead of a `platform.<x>_tickets` table + ops queue + approval UI. Capture the deferred surface in `docs/PRODUCTION-READINESS.md` with the volume threshold that would reopen it ("revisit at ~1 request/week") so the next sweep does not forget it exists.

## Known schema shape (checked before assuming a migration is needed)

- `platform.workspace_members` (migration 00002) already carries `role TEXT NOT NULL CHECK (role IN ('owner','admin','member'))`. Any admin-scope gate (e.g. minting keys with an elevated scope) checks this existing column — do NOT add a new `role` migration. Owner/admin are the elevated roles; member is baseline.
- `content.characters` (migration 00006) originally had `workspace_id NOT NULL`. If a feature needs workspace-null seeded rows (public catalog entries visible to all workspaces via RLS), the migration must both add the feature columns AND relax `workspace_id` to nullable — one migration, both changes.
- `platform.workspace_members` carries ONLY `(workspace_id, user_id, role)` — there is no `created_at`/`joined_at`. Any "member since" column in a members-list UI has no backing data; either add it in a migration deliberately or drop the field from the response rather than selecting a column that does not exist.
