# Render lifecycle: status, locking, list views, URLs

How `content.renders` relates to a project, and the four traps that cost
real debugging time here.

## Per-workspace concurrent-render cap

A single client in a loop against `/{kind}/projects/{id}/render` (or `/renders/{id}/retry`, or materialize-with-render, or series next-episode) otherwise monopolises the shared worker queue and burns Claude/ElevenLabs/MinIO quota before the first video ships. Mitigation is an in-memory per-workspace counter capped at 5 concurrent (env `RENDER_CONCURRENT_CAP`); any new render-launch handler must integrate.

### Shape

`apps/api/concurrent_render_gate.go` holds a `sync.Mutex`-guarded `map[workspaceID]*int32` of atomic counters. `tryAcquire` does a CAS loop against the per-workspace counter so slot admission is safe under concurrent requests without holding the map lock across a long handler. `release` clamps at zero — an over-release must NOT take the counter negative, or the next render bypasses the cap entirely. `nil` receiver treats every acquire as success (test-mode disable). Env `RENDER_CONCURRENT_CAP<=0` disables the gate; log a WARN at boot so a misconfig is loud rather than silent.

### Acquire-before-work + ownership transfer

Every handler that eventually launches `simulateRender` / `awaitTemporalResult` follows the same pattern — copy it literally, because the subtle part is the ownership transfer, not the gate call:

1. `if !s.renderGate.gate(w, p.WorkspaceID) { return }` immediately after the scope check, BEFORE any DB/pricing/credit work — fail fast so a looping client doesn't burn pricing-engine latency just discovering it's rate-limited.
2. Declare a `released := false` bool plus a `defer func(){ if !released { s.renderGate.release(p.WorkspaceID) } }()`. Every early-return path (project not found, cross-tenant 404, bad kind, pricing error, credit reservation failure, writeErr for any reason) now returns the slot automatically.
3. On successful goroutine launch (every spawn point — `go s.awaitTemporalResult(...)`, `go s.simulateRender(...)`), set `released = true` on the LINE ABOVE the `go` so the deferred release is a no-op and ownership transfers to the goroutine's own defer. Three spawn sites in `handleRenderProject` alone (`StartRender` success, `StartRender` error → simulator, no-Temporal → simulator); miss ANY one and the slot leaks because the goroutine will double-release what the handler already released.
4. `awaitTemporalResult` and `simulateRender` each `defer s.renderGate.release(rec.WorkspaceID)` at the top — the single, authoritative release site for a running workflow. Any new goroutine that ends a render MUST acquire this defer pattern.

### Coverage audit — grep every render-launch site before claiming a cap is enforced

`handleRenderProject` is NOT the only entry point. The three siblings that must also gate are: `handleRetryRender` (dashboard.go), the `if req.Render` branch in script-materialize (content.go), and `handleNextEpisode` (series.go). Grep `rg -n 'simulateRender\(|awaitTemporalResult\(|StartRender\(' apps/api/` whenever touching the gate; a new one-click render path added without the gate silently restores the loop-abuse hole.

### Tests that must exist

- `tryAcquire` admits exactly `cap` across many goroutines (race test — run under `-race`).
- `release` without a prior acquire clamps at zero.
- Nil receiver always admits and never panics on release.
- `gate` writes 429 with the `Retry-After` header and the `activeRenders`/`maxConcurrent` details.

## Status has TWO spellings for "finished"

`content.renders.status` holds **`done`**. The web layer tests for
**`succeeded`**. There is **no CHECK constraint**, so nothing rejects
either, and `RenderStatus` in `apps/web/lib/types.ts` originally omitted
`done` entirely.

Three bug shapes recur from this:

- Finished videos are classified as still rendering (card shows
  "making", routed to `/making`).
- A "projects with no successful render" query filtering on `'succeeded'`
  counts **every finished project as unfinished**.
- **Server-rendered route guards bounce ready videos to the "not ready"
  screen.** `videos/[id]/page.tsx` has had `if (render.status !==
  "succeeded") return <Making/>`; the library grid correctly accepts both
  spellings and marks the card ready, but the player route rejects every
  `done` render on arrival. Grid-is-green + player-says-not-ready is the
  signature.

**Accept both spellings in every comparison on `render.status`** — SQL
predicates, API classifiers, client classifiers, AND route guards.
Matching a single one silently excludes real rows, and the direction of
the error flips depending on which side you are standing on. When fixing
one site, `rg 'status\s*(===|!==|==|!=)\s*["'\'']succeeded["'\'']'` across
`apps/web` and the API — a single remaining comparison re-creates the
whole class. Before writing any
predicate on render status, confirm what the column actually contains:

```sql
SELECT status, count(*) FROM content.renders GROUP BY status;
```

A single terminal spelling plus a CHECK constraint is a small migration
and would retire this whole section — do it when touching this area.

## `done` is not enough — a playable render also needs `output_asset_id`

`content.renders.status = 'done'` means the WORKFLOW finished, not that the
video is playable. The MP4 lives in MinIO at
`openstudio-public/workspaces/{ws}/renders/{renderId}.mp4`, but the API
only surfaces it via `content.assets.s3_key` joined through
`renders.output_asset_id`. A `done` render with a NULL `output_asset_id`
serialises with no `outputUrl`, so `video-view.tsx` silently skips the
`<VideoPlayer>` and the page looks finished with no play affordance.

Two ways this breaks in practice:

- **Orphan-cleanup migrations null the pointer.** 00025 (`project_root`)
  deleted `content.assets` rows with `project_id IS NULL` and set
  `renders.output_asset_id = NULL` for every reference into them, to
  satisfy a NO ACTION FK before the DELETE. Every pre-migration `done`
  render now points at no asset even though the MP4 is still in the
  bucket. Idempotent recovery lives at
  `scripts/dev-native/backfill-render-assets.sh`: lists MP4s under
  `openstudio-public/workspaces/*/renders/*.mp4` via `mc`, filters to
  renders in that same workspace with `status='done' AND
  output_asset_id IS NULL`, inserts an asset row (`meta.backfill` set so
  rescued rows are distinguishable), and relinks. Keys with no matching
  render are expected (orphans from the project delete) and skipped, not
  errors.
- **A migration that tightens a column must be matched to every writer.**
  00025 also made `content.assets.project_id` NOT NULL, but
  `store.CompleteRender` still INSERTs an asset without a `project_id`;
  the tx rolls back and the next successful render never flips to `done`.
  When tightening a constraint in a migration, grep every INSERT/UPDATE
  into that table and update them in the same change; a worker that fails
  on commit after a long render burns credits and leaves the user staring
  at a stuck progress bar.

**Audit query — include the asset join, not just `status`.** The two-liner
that tells the truth:

```sql
SELECT r.status, (r.output_asset_id IS NOT NULL) AS has_output, count(*)
  FROM content.renders r GROUP BY 1, 2;
```

If a client surface counts "ready videos", it must require a non-null
`output_asset_id` (or a non-empty `outputUrl` in the API payload), not
`status IN ('done','succeeded')` alone.

## Which pipeline produced this MP4 — three paths, two silent fallbacks

The API has THREE code paths that can finish a render, and two of them
produce a video the user sees as finished regardless of whether the real
pipeline ran. Before concluding "the pipeline works" from a playable MP4,
confirm WHICH path produced it.

**The paths, in `apps/api/main.go` dispatch order:**

1. **Temporal workflow** (correct path) — `s.temporal.StartRender(wfIn)` →
   worker-core `pipeline` queue → `HiggsfieldGenerateActivity` for every
   broll storyboard scene, `TTSActivity` per turn → worker-render
   (`render` queue) composes the Remotion `MotionGraphics` composition and
   writes the MP4. This is the only path that produces real motion.
2. **`services/media/render` ffmpeg stub** (`realRender`) — fires when
   `s.temporal == nil` **OR** when `StartRender` returns an error. The file
   header literally says *"a bridge until apps/worker-render is wired via
   Temporal"*, but it is unconditionally wired at startup whenever
   `S3_ENDPOINT` is set (always, locally), so it is always available as
   fallback. Produces a 1080×1920 h264 MP4 whose video track is
   `color=0x2b1055` — a solid deep purple — with the title drawtext'd in
   the middle, muxed with fake TTS audio. Looks finished, plays, has the
   right dimensions and duration — nothing visibly tells the user it is a
   placeholder.
3. **`simulateRender` stage-only** — pure DB status progression, no media
   produced. Only reached when `s.renderer == nil`, i.e. MinIO is not
   configured. Rare in dev.

**Fingerprint test — one `ffmpeg` + one `grep` confirms which path ran.**
The stub's background colour is the unambiguous signature:

```bash
# Extract a mid-clip frame from the suspect MP4
ffmpeg -v error -ss 2 -i /tmp/last.mp4 -frames:v 1 /tmp/f.jpg -y
# If the frame is solid deep purple, grep the stub to confirm:
rg -n 'color=c=0x2b1055' services/media/render/
```

A hit means path 2 produced the file. The hex is nowhere else in the
repo. There is NO code path by which the Temporal + Higgsfield pipeline
produces a solid-colour frame — Higgsfield returns real motion or an
error — so a solid-colour MP4 is proof of the stub, not of a Higgsfield
misconfiguration.

**DB signature of the stub path:** `content.renders.workflow_id = ''`
(empty, not null) and `composition_id = ''`. The Temporal path writes a
real workflow ID at dispatch. A sweep for stub-produced rows:

```sql
SELECT count(*) FROM content.renders
 WHERE status = 'done' AND coalesce(workflow_id,'') = '';
```

If the number is non-trivial, the Temporal branch has been failing (or
never running) and every one of those MP4s is purple. Investigate by
grepping the API log for the fallback trace: `temporal StartRender failed;
falling back to in-process`.

**Fix shape — stop silently falling back.** The stub is a dev convenience
that became a correctness hazard the moment the Temporal path shipped.
Both entry points to it are now gated on `RENDERER_FALLBACK=1`:

- `apps/api/main.go` only wires `s.renderer = render.New(...)` when the
  env var is set. Without it, a Temporal `StartRender` failure returns a
  loud error rather than falling through to the ffmpeg stub.
- `apps/worker-core/main.go` `RenderInlineActivity` returns an explicit
  error at the top (`renderRemotion unavailable and RENDERER_FALLBACK is
  not set — refusing to produce a placeholder MP4`) when the env var is
  unset. The workflow surfaces this as a FAILED render.

Keep both guards aligned if you add a third fallback path. The stub is
still useful for isolated media-pipeline work on a laptop with no
Temporal; opting in is deliberate. **Pre-gate rows still exist in the
DB** — treat an empty `workflow_id` on a `done` row as the stub ran.

## Diagnosing WHICH activities fired — Temporal workflow history

For any render whose output looks wrong (purple frame, missing broll,
title-card-only), the workflow history tells you exactly which
activities were scheduled, which failed, and with what error — long
before you need to grep logs. Dump it as JSON and filter in Python:

```bash
temporal workflow show --namespace default -w render-<renderID> --output json \
  | python3 -c "import json,sys
d=json.load(sys.stdin)
for e in d.get('events',[]):
  a=e.get('activityTaskScheduledEventAttributes') or {}
  t=a.get('activityType',{}).get('name')
  if t: print(e['eventId'],'SCHED',t,'q=',a.get('taskQueue',{}).get('name'))
  f=e.get('activityTaskFailedEventAttributes')
  if f: print(e['eventId'],'FAIL ',(f.get('failure',{}).get('message') or '')[:200])
  to=e.get('activityTaskTimedOutEventAttributes')
  if to: print(e['eventId'],'TIMEOUT',(to.get('failure',{}).get('message') or '')[:200])"
```

Signature of a working motion-graphics render: `ModerateActivity`,
`TTSActivity` (one per turn), `WhisperTimingsActivity`,
`HiggsfieldGenerateActivity` (one per `broll` scene), then
`renderRemotion` on queue `render`. **If `RenderInlineActivity` appears,
the stub ran.** If `HiggsfieldGenerateActivity` is absent on a project
with storyboard scenes, the storyboard didn't reach the workflow input
(check `buildMGRenderPayload` and that `settings.motionGraphics.script`
has the right shape — the legacy wizard writes `settings.wizard.*`
instead, and the renderer ignores it, so turns come back empty and no
fan-out happens).

## External-provider credit failures masquerade as pipeline bugs

Higgsfield returns `HTTP 403 {"detail":"not_enough_credits"}` when the
account balance is zero. The adapter propagates this as an activity
error, Temporal retries hit the same wall, the storyboard is marked
degraded, and the workflow drops through to `renderRemotion` with no
visuals. With the fallback gate OFF this now surfaces as a FAILED
render; with it ON (or before the gate), it reaches the stub and
produces purple. **Before concluding "Higgsfield is misconfigured", probe
the provider directly** — the 403 vs 401 distinguishes credit vs key:

```bash
curl -sS -o /tmp/hf.json -w 'status=%{http_code}\n' \
  -X POST https://api.higgsfield.ai/bytedance/seedance-2.0/text-to-video \
  -H "Authorization: Key $HIGGSFIELD_API_KEY" -H "Content-Type: application/json" \
  -d '{"prompt":"test","duration":4,"aspect_ratio":"9:16"}'
cat /tmp/hf.json
```

`401` → key invalid or malformed; `403 not_enough_credits` → account
balance is zero (fix is at console.higgsfield.ai, not in code);
`200/202` with a `request_id` → provider works, bug is elsewhere.
Same pattern applies to any paid external provider — add a one-line
direct probe to the diagnosis flow before touching wiring.

## worker-render "No workflows registered" is EXPECTED

`apps/worker-render` is an **activity-only** worker (it registers
`renderRemotion`, no workflows). The Temporal SDK logs
`[WARN] No workflows registered, not polling for workflow tasks
{ sdkComponent: 'worker', taskQueue: 'render' }` at boot. This is
normal, not a misconfiguration. The matching info lines above it
(`worker ready`, `Worker state changed … state: 'RUNNING'`) and a
`Pollers: activity … LastAccessTime: … seconds ago` row in
`temporal task-queue describe --task-queue render --namespace default`
are what prove the activity side is live. Don't chase this warning.

## `AI_PROVIDER_MODE=fake` is a red herring for VideoGen

`services/ai-gateway/factory/factory.go` does NOT check `AI_PROVIDER_MODE`
for the VideoGen slot. It picks Higgsfield the moment `HIGGSFIELD_API_KEY`
is present (`higgsfield.New()` returns non-nil), then falls back to
`wan21comfy` if `COMFYUI_URL` is reachable, then to the fake. So a
`.env` with `AI_PROVIDER_MODE=fake` AND `HIGGSFIELD_API_KEY=…` wires the
REAL Higgsfield adapter — the mode flag has no effect on this capability.

Same pattern for ImageGen (`IMAGE_GEN_REAL_ADAPTER=1` is the opt-in, not
the mode flag) and for Decision (`PROVIDER_DECISION=fake` is the per-slot
override). The mode flag is historical and only consulted by callers that
choose to branch on it explicitly — grep before assuming it gates
anything:

```bash
rg -n 'AI_PROVIDER_MODE' services/ apps/
```

To pin an individual capability to fake while keys are present, use the
per-slot override env (`PROVIDER_TEXTGEN=fake`, `PROVIDER_ASR=fake`,
`PROVIDER_DECISION=fake`) — those ARE checked by the factory. No such
knob exists for VideoGen / ImageGen / TTS as of this writing; the only
way to disable them is to delete the key (and restart the processes that
read it — see the `.env` restart rule in the main SKILL).

## A render in flight makes the project READ-ONLY

The worker is handed the script, the approved audio key and the look **at
dispatch time**. An edit landing mid-render produces a video matching
neither the old inputs nor the new ones, and the user cannot tell which
they got.

Semantics, all load-bearing:

- **Only `queued` and `running` lock.** `failed` must NOT — that is
  precisely when the user needs to edit and retry; locking it strands them
  with no way to fix the inputs. A finished render must not lock either
  (see the next section).
- **Enforce it API-side, on every mutation path**, not just in the UI: the
  wizard progress PATCH, the script-body PATCH, and `stageGuard` (which
  covers all four generation stages, so a fifth stage inherits the check).
  A public API key bypasses the UI entirely.
- **Check it AFTER the ownership check**, so a foreign project still
  reports NOT FOUND rather than leaking its render state.
- **Fail CLOSED.** If the lock cannot be read, refuse the edit: allowing
  it risks corrupting a render in progress, while refusing costs a retry.
- Report the lock on the project GET (`editable`, plus the holding render
  id/status) so the client can render read-only instead of inviting an
  edit the API will reject with 409.

**Mutation-test a gate like this in BOTH directions.** A lock that is too
eager is as broken as one that is too lax, and only the lax direction is
obvious. Verify that disabling the lock fails tests AND that extending it
to terminal states fails a different test.

## Retry is same-id, not new-id — reset the row, restart the workflow

A retry is "run THIS version again," not "make a new version that remembers
the old one." The render id is the identity of a version in the UI, the
publications table, the revisions table, the Library tile grid, and any
link the user has already shared. Minting a fresh id on retry orphans
those references and makes the version grid grow one tile per failure —
already-paid work the user cannot delete without taking the whole project
with it.

**The shipped `POST /api/v1/renders/{id}/retry` handler is a trap.** As
originally written it called `store.RetryRender`, which INSERTs a new
render row with a `retried_from` backlink, and then kicked the
`simulateRender` fake-progression goroutine — no `temporal.StartRender`,
no real workflow, no vendor submit. The UI would show a new tile that
marches to 100% in two seconds with no video. If you touch retry, verify
both: new row (should be absent) and `temporal.StartRender` call
(should be present).

**The handler shape that works:**

1. `s.db.ResetRenderForRetry(ctx, ws, renderID)` — a scoped UPDATE that
   flips status/stage back to `queued`, zeroes `progress`, NULLs
   `error_code/message`, `workflow_id`, `output_asset_id`, `duration_ms`,
   `completed_at`, `reservation_id`, `snapshot_hash`, and only matches
   rows where `status IN ('failed','cancelled')`. The guard clause is
   load-bearing: a double-click or a stale tab must not clobber an
   in-flight or completed render. Returns 404 when the row is not
   retryable so the UI shows a plain error rather than silently
   corrupting state.
2. Reload the project (`s.db.GetProject`) — the retry handler needs the
   same Kind, Title, Scenes and Settings the first dispatch used to
   build the workflow input.
3. Re-price with the per-kind rule (cinematic reads
   `settings.cinematic.modelTier` + `durationSec`; others use the
   4s/scene heuristic) and `s.ledger.Reserve` fresh credits — the old
   reservation was released on the failure path.
4. `s.db.SetRenderReservation(ctx, ws, renderID, newResID)` — stamp the
   fresh reservation onto the same row so the eventual release path
   (which reads `renders.reservation_id`) refunds the correct hold.
5. Mirror the in-memory `renderRec` using the SAME id, then build `wfIn`
   the same way `handleRenderProject` does and call
   `s.temporal.StartRender(wfIn)`. The returned workflow id becomes
   `render-<renderID>` (deterministic), which Temporal rejects as
   duplicate if an earlier run of the same id has not reached a terminal
   state yet — another reason step 1's guard matters.

Extracting these steps into a shared helper with `handleRenderProject`
is cleaner than copy-paste, but the two handlers diverge enough (new
vs reused id, project load vs project cache lookup, scope checks) that
the mechanical duplication has shipped twice without drift complaints —
defer the extraction unless a third caller appears.

## Retry UI: button on the failed VERSION tile, not the project header

**Rule.** The "Try again" affordance belongs INSIDE the failed version's
grid tile, on top of the danger overlay — never as a general action in
the project header or action bar.

**Why.** A project header button is ambiguous: a project with three
versions where one failed could mean "retry the failed one" or "make a
fourth." The failed-tile placement makes the target unmistakable AND
keeps the retry affordance invisible on healthy projects, which is the
right default (no error → no error-recovery UI). It also lets a user
with several failed versions retry each independently without a modal
asking which one.

**Shape in `apps/web/app/(app)/projects/[projectId]/project-client.tsx`.**
State is per-tile (`retryingId: string | null`), not project-level, so a
Try-again on one tile does not disable Retry on sibling failed tiles —
and the loading spinner lands on the exact tile being retried. The
button calls `e.stopPropagation()` so clicking it inside the tile does
not also fire the tile's "watch this version" click. Pass
`disableRetry={!!making || !!retryingId}` so a user cannot queue
parallel retries while one is in flight. Button icon: `RotateCw` from
lucide-react.

**Do NOT remove the "Make another like this" header link in the same
pass.** They are different actions: Retry re-runs the failed version
against the SAME settings, Make-another sends the user to the editor
with the project loaded for a brand-new render. Users ask for both
independently.

## Surface the vendor's rejection message, or the user retries blindly

`content.renders.error_message` is what the WORKFLOW returned, not what
the vendor returned — the activity error bubbles up through Temporal
and `awaitTemporalResult` stores the wrapped form. A real row for a
Higgsfield copyright block reads literally:

```
workflow execution error (type: , workflowID: render-rnd_…, runID: …): \
  cinematic: vendor reported failure: This request was blocked due to \
  potential copyright restrictions. Please try a different prompt or \
  reference media.
```

If the failed version tile only shows an alert triangle + "Didn't
finish" + a Retry button, the user clicks Retry forever with the same
prompt and never discovers the real block.

**Rule.** When a render is `status='failed'` with a non-empty
`error_message`, the failed version tile must surface a user-legible
summary of that message (truncated/wrapped) alongside the Retry button,
AND an "Edit prompt" secondary action that routes to the project's
`editHref` — a blind retry on a vendor-content block reproduces the
block, so sending the user to the editor is the correct recovery.

**Formatter (the envelope-stripping rule).** The DB string is useless
raw: the Temporal `workflow execution error (type: …, workflowID: …,
runID: …):` prefix dominates every tile and buries the one sentence
that tells the user what to do. Normalise before render with a
`friendlyFailureMessage(raw)` helper (one in `apps/web/lib/projects.ts`
or adjacent):

1. Strip the Temporal envelope: `/^workflow execution error \([^)]*\):\s*/i`.
2. Strip one of the kind-branch prefixes: `/^(cinematic|render|motion-graphics|workflow)\s*:\s*/i`.
3. Strip `/^vendor reported failure\s*:\s*/i`.
4. Collapse whitespace with `.replace(/\s+/g, " ")`, cap at ~160 chars with an ellipsis, fall back to a generic sentence when the result is empty.

Render the summary with the full raw `error_message` on the DOM
`title=` attribute so power users / support can inspect the chain
without a DB lookup — truncation is the UX, not the storage.

**Shape.** `apps/web/lib/types.ts`'s `Render`/`ProjectVersion` carry
`errorCode` + `errorMessage` from the API payload — `renderSummaryJSON`
in `apps/api/lists.go` emits both (`omitempty`) and `RenderSummary` in
`services/db/store/lists.go` SELECTs them via `COALESCE(…,'')`. When
adding a new rendering kind that can fail with a user-actionable error,
verify both the SELECT and the JSON emitter — a kind added without the
`COALESCE` will scan-error on NULL, and a kind added without the JSON
emitter will show the generic fallback forever.

Mirror the rule on the server: when the activity error implies the
vendor rejected the content (strings matching `copyright`,
`moderation`, `blocked`, `nsfw`), surface `error_code` as a stable
machine value (`VENDOR_CONTENT_BLOCKED`) in the API payload — the UI
then branches on code, not on substring-matching the vendor's prose
which drifts between vendors.

## Editing a finished project ADDS a render; it never overwrites

A render is a dated artefact of specific inputs. Replacing it silently
changes a video the user may already have shared or linked, and the
overwrite path has no safe failure mode — if the new render fails you have
either destroyed the old video or must explain which one is on screen.
`content.renders` already supports many rows per project.

So: the edit affordance on a finished card leads to the project, editing is
allowed, and "Make video" produces the NEXT render. Nothing is destroyed.

## A list built on renders cannot show a project that has none

Renders are the storage for finished videos here, so a project abandoned
mid-wizard has no render row and is invisible to every render query. Any
"show me my work" surface needs a SECOND source
(`GET /api/v1/projects/drafts`) and must treat the two as different row
types, not coerce one into the other.

Two pitfalls when adding it:

- **An empty-state early return keyed on one list hides the other.**
  `if (renders.length === 0) return <Empty/>` buries every draft behind
  "nothing here yet" — the exact bug the feature exists to fix. Require
  both lists empty.
- Derive "unfinished" with `NOT EXISTS (... status IN ('done','succeeded'))`
  rather than comparing the LATEST render's status: an older successful
  render still means the project produced a video.

## Presigned URLs are not durable — persist KEYS and re-sign on read

MinIO/S3 presigned URLs expire (6h here, `presignTTL`). Persisting one
gives you a surface that renders perfectly with every row 403ing, which is
worse than the feature being absent because it looks functional.

The working shape:

1. Persist the object **key** only; never the signed URL.
2. Re-sign on read in the project GET, returning a `key -> url` map.
3. On the client, prefer the freshly signed URL and fall back to any stored
   one (same-session convenience), never the reverse.
4. Omit a key that cannot be signed rather than mapping it to `""` — a
   missing URL can render as "(no preview)" or a disabled control, whereas
   an empty string renders a dead player.

**Sign EVERY key, including the primary one.** Signing only the per-item
keys and forgetting the single stitched/primary key left the main player
with a key and no URL, so it reported "no audio to play yet" for audio that
existed and had played minutes earlier. Enumerate the keys from the stored
blob in one helper rather than handling the primary asset separately.
