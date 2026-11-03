# Vendor-rendered kinds

Use when the frames come from an external generative-video API (Higgsfield,
Runway, etc.) rather than from the Remotion compositor. These kinds plug
into the kind registry at the same level as `motion-graphics` but take a
different path through the stack.

## What changes vs a Remotion kind

The 6 wire points in the main skill still apply, with two swaps:

- Wire-point 5 (`packages/compositions`) is **skipped**. There is no
  Remotion composition for this kind.
- Wire-point 6 (`renderRemotion.ts`) is **replaced** by a defensive guard:
  a vendor-rendered kind reaching the Remotion activity is a
  workflow-routing bug, so the `kind → compositionId` switch errors with
  the kind name instead of falling through to a default composition.

Two new wire points take their place:

5'. **A sibling Go worker app** under `apps/worker-render/<kind>-renderer/`
   on its own Temporal task queue named for the kind. Go, not Node — a
   Remotion worker is wrong tooling for submit/poll/download. Follow ADR
   0006's split-queue reasoning; do not overload the `render` queue with
   a provider-call branch, that queue is already a starvation hotspot.

6'. **Workflow branch in `apps/worker-core/main.go`.** `GenerateVideoWorkflow`
   branches on `in.Kind == "<kind>"` BEFORE the Remotion dispatch and
   schedules its activities on the new queue with
   `TaskQueue: cfg.TemporalTaskQueue<Kind>`. The vendor-rendered path
   never schedules `renderRemotion`.

## Kind registry

Register with `composition=""` — the empty string is the signal that
Remotion is not the renderer. `/api/v1/kinds` still surfaces the kind;
consumers that read `composition` for a Remotion ID must tolerate the
empty value for this category.

```go
{"<kind>", "<route>", "", "video", cfg.Kind<X>Enabled},
```

## Pricing shape

Short-circuit the shared `audio`/multiplier path. A kind whose vendor
controls audio and resolution has no business billing the per-second TTS
line or the motion-graphics quality×aspect multipliers. Add the branch
right after the base line-item is appended and before the shared `audio`
append:

```go
if r.Kind == Kind<X> {
    // base + per-tier/per-second provider surcharge, nothing else.
    ...
    return &Quote{Total: total, Version: Version, LineItems: items}, nil
}
```

Cover with a test asserting NO line labelled `audio` is emitted, plus
the standard anchor (one exact-total test), ordering (`sd < hd < 4k` or
equivalent), default-tier, unknown-tier 400, and a zero-math clamp (1s
duration must still carry a visible charge, not 0 credits).

## Config flags that must land in the same commit

- `cfg.Kind<X>Enabled` + its `KIND_<X>_ENABLED` env (default true in dev).
- `cfg.TemporalTaskQueue<X>` + `TEMPORAL_TASK_QUEUE_<X>` env (default the
  kind id). The worker reads it at boot; the workflow dispatch reads it
  per activity. One source of truth, no hard-coded queue names.

## Grep before writing an adapter

Before scaffolding, grep `services/ai-gateway/<provider>/`. The gateway
often already has the provider's HTTP client wired for an earlier
capability, and a second parallel implementation drifts on retry policy,
cost tracking, and env-var names. Extend the existing adapter with a
per-request override (model path, upload URL fetch) instead of writing a
second HTTP client.

## Naming: confirm typos before baking them in

When the user types a word that looks like a typo of a common English
term in a naming decision (folder, kind id, Go enum, queue name,
migration name), ask ONCE before honouring or correcting. A typo baked
into a kind id spreads through 6+ wire points, the queue name, the
migration file, and the public URL — and a silent correction without
confirmation is worse because the user's next prompt still spells it the
way they typed it. One clarify call is cheap; the answer sticks for the
whole rollout.

## Operator-only live verification

External-provider renders cost real money per submit. The agent runs
httptest-backed unit tests ONLY; the live-API curl E2E is operator-run
after the operator has topped up the vendor account and set the API-key
env var. The repo invariant on reviewers not running live-spend scripts
applies here by extension.

## Phased delivery outline

A new vendor-rendered kind is multi-phase infra per the main invariant.
One commit per phase, each buildable in isolation:

1. ADR + config flag + pricing + kind registry entry + display map.
2. Zod schema + server-side model registry (`apps/api/<kind>_models.go`).
3. Adapter extensions (per-request model path, signed-upload-URL if the
   vendor supports reference uploads).
4. New Go worker app + FIVE activities (Submit, Poll, Upload, QC, Cancel)
   + httptest tests. Three-activity minimum (submit/poll/upload) is
   corner-cutting: without a dedicated QC activity, a vendor returning
   `completed` + a zero-second video becomes a successful render in the
   library; without a dedicated Cancel activity dispatched by a workflow
   signal, an API cancel-handler timeout leaks billing because polling
   stops but the vendor keeps rendering. Bounded `MaximumAttempts: 3`
   RetryPolicy on every activity that calls the vendor; polling backoff
   lives inside the activity (internal exponential cap ~30s), NOT in
   Temporal retry (`MaximumAttempts: 1` on the poll activity so retries
   aren't double-counted).
5. `worker-core` workflow branch + API `POST /api/v1/<route>/projects` +
   render create + ownership-checked cancel handler.
6. `apps/web/app/(app)/create/<route>/` wizard matching the motion-graphics
   resume pattern.
7. OTEL spans + `external_calls` audit rows with `peer=<provider>` per
   ADR 0012.
8. Defensive guard in `renderRemotion.ts`, docs, verification notes.

## Hybrid webhook + polling: webhook is a nudge, polling is truth

When the vendor offers webhooks, DO NOT replace polling with them — add
webhooks as an optimisation on top of a complete polling implementation.
Reasoning that falls out every time: webhooks need public HTTPS ingress
(no ngrok in native dev), vendors rarely sign them (Higgsfield doesn't),
and terminal states like `canceled` are often not delivered. Treat the
webhook body as a NUDGE-TO-REFETCH, never as source of truth — on
arrival, signal the workflow with the status + URL, and let the workflow
go confirm against the authenticated status endpoint before trusting it.

Shape in `runCinematic`-style workflows:

```go
// Only enable the selector when a webhook URL was threaded through;
// an empty URL means polling-only (no signal will ever arrive, so
// avoid blocking on a channel that cannot receive).
if in.WebhookURL != "" {
    pollCtx, cancelPoll := workflow.WithCancel(pollActivityCtx)
    pollFuture := workflow.ExecuteActivity(pollCtx, PollActivity, ...)
    sigCh := workflow.GetSignalChannel(ctx, SignalWebhook)
    cancelCh := workflow.GetSignalChannel(ctx, SignalCancel)
    sel := workflow.NewSelector(ctx)
    sel.AddReceive(sigCh, ...)   // webhook arrival cancels poll
    sel.AddReceive(cancelCh, ...) // user cancel dispatches CancelActivity
    sel.AddFuture(pollFuture, ...)
    // loop sel.Select until a terminalReady flag flips
} else {
    // polling-only path, no selector
    workflow.ExecuteActivity(ctx, PollActivity, ...).Get(ctx, &terminal)
}
```

Webhook ingress MUST sit INSIDE the chi `/api/v1` mux but OUTSIDE the
auth middleware — the vendor cannot carry a session. The handler replies
200 unconditionally so the vendor stops retrying; it then dispatches the
signal in a goroutine so the HTTP response has already landed before the
Temporal call. Add a scope-less `GetRenderAny(ctx, renderID)` to
`services/db/store` for this one caller and document it inline as
'webhook-ingress-only; workspace scoping stays the primary authorization
boundary everywhere else'.

**Enforce 'nudge, not truth' in code, not just in the doc comment.** The
posture is only real if the signal struct physically cannot carry vendor
fields:

- The signal payload struct carries ONLY an opaque nonce (or empty map).
  No `Status`, no `VideoURL`, no `Error`. A reviewer who sees any of
  those on a webhook signal has caught a regression — the handler then
  copies them into `terminal` and feeds attacker-controlled URLs into
  the Upload activity. The ADR comment above the handler is not a
  substitute: a prior implementation documented the correct posture in
  prose and then violated it two lines below, and type-level emptiness
  is the only fix that survives refactors.
- On signal receive, cancel the long poll AND run a fresh short poll on
  a NEW `workflow.WithActivityOptions(ctx, ...)` context. Reusing the
  cancelled `pollCtx` returns `context canceled` from the confirm
  activity; the derivation must come from the parent `ctx`, not from
  the context you just cancelled. 30s StartToCloseTimeout, 1 min
  ScheduleToCloseTimeout, `MaximumAttempts: 3` so transient vendor
  blips are retried without re-entering the long polling loop.
- Handler ordering: rate-limit check FIRST (short-circuit on abuse
  without paying body-parse cost), then `http.MaxBytesReader(w, r.Body,
  16<<10)` and `io.Copy(io.Discard, r.Body)` (we don't need the bytes),
  then always 200. A per-IP limiter from `services/ratelimit` keyed by
  `net.SplitHostPort(r.RemoteAddr)` (chi.RealIP already extracted) with
  capacity 10 / refill 3s absorbs legitimate vendor retry bursts and
  caps a bare curl loop. 429 responses MUST NOT enqueue a signal.
- Pin all three with a test file (`<kind>_webhook_test.go`): a hostile
  body ('attacker.example' URL) must produce a signal whose serialised
  payload contains neither the hostile string nor any of status/
  videoURL/video/error/url keys; a 1 MiB body returns 200 without OOM;
  the Nth+1 burst from one IP is 429 with Retry-After, a different IP
  is not blocked, and the 429 call does NOT add a signal. Without these
  assertions a future refactor silently reverts the posture.

## Vendor-download activities: bound the HTTP client, cap the body, heartbeat the read

Any activity that GETs a vendor-returned URL (Upload, image fetch,
reference-mirror) must not use `http.DefaultClient` and must not call
`io.ReadAll` on the body. `DefaultClient.Timeout == 0`; a slow-loris CDN
ties the activity goroutine up for the full `StartToCloseTimeout` with no
heartbeat progression. `io.ReadAll` on a chunked transfer-encoded
multi-GB body OOMs the worker before any Temporal timeout fires.

Shape:

- Package-level `var uploadHTTPClient = &http.Client{Timeout: 4 * time.Minute}`
  (or similar bound < Temporal's StartToCloseTimeout) and use it for the
  GET. A dedicated client also keeps a future `httptrace`/retry change
  from touching every call site.
- Package-level cap, e.g. `const uploadMaxBytes = 500 << 20`. Wrap the
  response body in `io.LimitReader(resp.Body, uploadMaxBytes + 1)` — the
  `+1` makes overrun visible so an exactly-at-cap body still succeeds
  while a one-byte-over body fails. Return a sentinel `ErrBodyTooLarge`
  so callers can match without wrapping-chain plumbing.
- Read the body in 64 KiB chunks into a `[]byte`; every ~4 MiB call
  `heartbeatSafe(ctx, "download-progress", len(buf))` so a steady but
  large body still reports liveness. Check `ctx.Err()` on every chunk
  so a cancelled workflow surfaces `context.Canceled` immediately
  instead of waiting for the HTTP timeout.
- Pin with tests: oversize → `ErrBodyTooLarge`, exactly-at-cap →
  success with all bytes, slow-reader + cancelled ctx → `context.Canceled`,
  and a `TestUploadHTTPClientHasTimeout` guard asserting `uploadHTTPClient.Timeout != 0`
  so a future revert to `DefaultClient` is caught at test time.

## Model picker: NEVER let a reference-image request fall through to text-to-video

**Rule.** A server-side model picker (`chooseCinematicModel`-style)
selecting from a catalog of mixed text-to-video + image-to-video models
must return `(nil, false)` — never a text-to-video model — when the
request carries a reference image and no I2V entry fits the other
constraints (duration, aspect, audio). A text-to-video model silently
drops `referenceImageUrl` from the submit body; the vendor sees prompt
only and generates a stranger. For the influencer path this is the
worst possible failure mode: the user shipped a portrait and got a
different person back.

**Failure shape.** A naive "first fit wins" loop over the catalog with
a flat `cinematicModelFits` check will reject the only verified I2V
entry (e.g. because `AudioOn=true` and no I2V model supports audio),
then continue iterating and return the first T2V model that happens to
fit. Submit returns 202, Higgsfield renders prompt-only, user opens
the mp4 to see a stranger. The DB signature is a `done` or `failed`
render whose project `settings.cinematic.referenceImageUrl` is empty
AND whose `modelPath` ends in `/text-to-video` — confirm with the
obs DB: `SELECT url, convert_from(req_body,'UTF8') FROM external_calls
WHERE peer='higgsfield' ORDER BY started_at DESC LIMIT 3` — if the
body has no `image_url` key, the picker fell through.

**Correct picker shape.**

```go
func chooseCinematicModel(shape cinematicRequestShape, pinnedT2V, pinnedI2V string) (*CinematicModel, string, bool) {
    // Fast path: operator-pinned model that still fits.
    pinned := pinnedT2V
    if shape.HasReferenceImage { pinned = pinnedI2V }
    if pinned != "" {
        if m, ok := cinematicModelByPath(pinned); ok && cinematicModelFits(m, shape) {
            return m, "", true
        }
    }
    // Normal path: first verified model that fits as-is.
    for i := range cinematicModels {
        if cinematicModelFits(&cinematicModels[i], shape) {
            return &cinematicModels[i], "", true
        }
    }
    // Nothing fit. For reference-image requests try ONE relaxation —
    // audio off — since identity preservation beats sound. Returns a
    // user-facing note so the UI can toast "We turned sound off to
    // keep their face in the video."
    if shape.HasReferenceImage && shape.AudioOn {
        relaxed := shape; relaxed.AudioOn = false
        for i := range cinematicModels {
            m := &cinematicModels[i]
            if cinematicIsImageToVideo(m) && cinematicModelFits(m, relaxed) {
                return m, "We turned sound off to keep their face in the video.", true
            }
        }
    }
    // Reference-image request with no matching I2V model: refuse. The
    // handler returns 400 with a plain-language message — DO NOT fall
    // through to a text-to-video model that would drop the photo.
    return nil, "", false
}
```

**Thread the downgrade note through the brief and the response.** The
brief struct carries a `warning string` field; the handler emits it as
`response.note` so the UI can toast it right before navigating to the
project. Without a user-facing note the audio downgrade is silent and
indistinguishable from "the audio toggle is broken" when the user
replays the clip.

**Also:** the brief's `audio` field must be `req.AudioOn && model.SupportsAudio`
so an unverified-model-with-audio pinned-path still turns audio off at
submit time. The picker's downgrade covers the auto-pick case; the
brief's `&&` covers the explicit-modelPath case.

**Pin with TWO regression tests, not one.** One for each failure mode:

```go
// 1. Audio-on + reference image must downgrade audio, keep I2V.
func TestChooseCinematicModel_ReferenceImageAudioOnDowngradesAudio(t *testing.T) {
    m, warn, ok := chooseCinematicModel(cinematicRequestShape{
        HasReferenceImage: true, AspectRatio: "9:16", DurationSecs: 5, AudioOn: true,
    }, "", "")
    if !ok { t.Fatal("expected picker to downgrade audio, not refuse") }
    if !cinematicIsImageToVideo(m) {
        t.Fatalf("picker fell through to %q (mode %q); must stay I2V to preserve the photo", m.Path, m.Mode)
    }
    if warn == "" { t.Fatal("expected a user-facing warning") }
}

// 2. Reference image + impossible constraint must REFUSE, not fall through to T2V.
func TestChooseCinematicModel_ReferenceImageNeverFallsThroughToT2V(t *testing.T) {
    if m, _, ok := chooseCinematicModel(cinematicRequestShape{
        HasReferenceImage: true, AspectRatio: "9:16", DurationSecs: 60, // beyond every I2V clamp
    }, "", ""); ok {
        t.Fatalf("picker returned %q for a reference-image request no I2V can serve; must refuse", m.Path)
    }
}
```

The second test is the one that locks the invariant forever — a future
"simplification" that re-introduces the fall-through loop fails it
immediately. The first test alone passes with a buggy picker that
happens to find an I2V model for the common case.

## Picker fixes do NOT auto-repair existing project rows — retry handlers must validate stored settings

**Rule.** A vendor-rendered retry handler reads `project.settings.<kind>`
verbatim and passes `modelPath` + `referenceImageUrl` straight to the
workflow input. If the project was first created with a buggy picker
(e.g. before the "never fall through to T2V" fix shipped), its stored
`settings.<kind>.modelPath` is a text-to-video path and `referenceImageUrl`
is `""`. Fixing the picker LATER does not rewrite that row — every retry
on that project reproduces the original bug (same prompt-only submit,
same wrong-person video). The user sees "I retried after you fixed it,
still wrong," which looks like the fix did nothing.

**Why `ResetRenderForRetry` does not catch this.** The reset only touches
the `renders` row (status/stage/progress/workflow_id/reservation); the
`projects.settings` JSONB is untouched because it is the user's input,
not pipeline state. That is correct for the general case (a user who
editses prompt+aspect expects their edits to persist across a retry) and
wrong for this one (a server-picked model that is now wrong for the
request shape).

**Detect-and-refuse on the retry path for reference-image kinds.** Before
dispatching, re-validate the stored settings against today's picker
invariants. For cinematic/influencer-video and any future image-to-X
kind:

```go
if pr.Kind == "cinematic" && proj.Settings != nil {
    cs, _ := proj.Settings["cinematic"].(map[string]any)
    mp, _ := cs["modelPath"].(string)
    ref, _ := cs["referenceImageUrl"].(string)
    hadRef := pr.SourceInfluencerID != "" // or an explicit flag in settings
    if hadRef && (strings.TrimSpace(ref) == "" || !cinematicIsImageToVideoPath(mp)) {
        writeErr(w, errs.New(errs.CodeConflict,
            "This video was made before a fix shipped. Click Edit prompt to re-run it with the right settings."))
        return
    }
}
```

The editor's resume path (`/create/<route>?project=<id>`) rebuilds the
brief through `resolveCinematicBrief`, which runs the current picker and
overwrites `modelPath` + `referenceImageUrl` in the stored settings on
the next create/update. That is the only path that heals the row —
retry cannot.

**Pin with a test.** Insert a project row with the broken shape
(`modelPath` on a T2V path, empty `referenceImageUrl`, non-null
`source_influencer_id`), post retry, assert 409 and that the error
string routes the user to Edit. Without this a future refactor that
"simplifies" the retry handler by trusting stored settings re-opens
the silent-stranger failure for every pre-fix project in the DB.

**Diagnostic step when a user reports "retried after your fix, still a
stranger."** Query the project settings first — if the stored
`modelPath` ends in `/text-to-video` or `referenceImageUrl` is empty,
the row predates the picker fix and no amount of retry will heal it.
Expected support reply: "Edit the project (not retry), or delete it and
make a new one." The retry button should refuse rather than deferring
this conversation to a shipped bad render.

## Signed-upload-URL pattern (vendor-hosted reference images)

Two-step dance: server fetches a presigned PUT URL + headers from the
vendor, browser PUTs the file bytes directly to that URL with every
returned header forwarded verbatim and NO Authorization header on the
PUT (the signed URL IS the credential; adding your Authorization header
either 400s or leaks the API key to storage logs). Record and USE the
`public_url` only after the PUT returns 2xx — a race between an in-
flight PUT and a submit that references the public URL burns a vendor
render slot on a 404. Never log signed upload URLs: they contain the
vendor's internal object key and expire slowly.

## Mirror our stored bytes to the vendor's CDN before image-to-* submits

**Rule.** When a handler already has an image in our own public bucket and
needs to pass it to a vendor image-to-video or image-to-image endpoint, it
MUST still fetch the bytes and re-upload them via the vendor's own
`UploadReference`-equivalent — do NOT pass our `publicOutputURL(key)`
straight through as `image_url`. The vendor's rendering workers run in
their cloud; they cannot reach `http://localhost:9000` in dev, and in
prod `MEDIA_PUBLIC_URL` is typically a private-VPC MinIO or S3 endpoint
that is not routable from vendor workers.

**Failure mode when violated.** Submit returns 202 cleanly (the vendor
accepts the URL string without fetching it); the status endpoint flips
to `failed` ~3-7 seconds later with `"Could not download the file.
Provide a direct file URL that can be opened without signing in."`
No credits consumed (vendor failed pre-render), but the user sees a
broken feature and the operator spends time thinking it's a vendor
outage.

**ADR comments do not enforce this.** A past iteration had ADR §10
stating "API uploads the portrait bytes to Higgsfield's upload endpoint
(our storage is not reachable from the internet)" — and shipped the
handler that passed the storage URL anyway. The rule holds only when
the code physically does the upload; wire it into the handler, don't
leave it as prose.

**Shape.** The vendor adapter already carries this (`UploadReference(ctx,
data, ct) → url`) because the influencer-photo path uses it. Call it
from every new image-consuming handler:

```go
// Fetch from our storage
data, ct, derr := files.Get(ctx, portraitKey)
if derr != nil {
    slog.Error("<kind>: image fetch failed", "err", derr)
    writeErr(w, errs.New(errs.CodeInternal, "We couldn't read that image. Please try again."))
    return
}
// Mirror to the vendor's CDN
vendorURL, uerr := v.UploadReference(ctx, data, ct)
if uerr != nil {
    slog.Error("<kind>: UploadReference failed", "err", uerr)
    writeErr(w, errs.New(errs.CodeProviderUnavailable, "We couldn't send that to the renderer. Please try again."))
    return
}
// Submit with the vendor-hosted URL, never with publicOutputURL(key)
brief, aerr := s.resolveCinematicBrief(cinematicCreateRequest{..., ReferenceImageURL: vendorURL})
```

**Pin with a test, not with the ADR comment.** The vendor and files
seams are both fakes in the test harness (`fakeInfluencerVendor` has an
`uploads` counter; `fakePortraitFiles.files` records keys written via
`PutPublic`). Add two assertions:

1. `UploadReference` was called exactly once (`fv.uploads == before + 1`
   — otherwise the handler regressed to passing a URL straight through).
2. The stored key the handler read from exists in `ff.files` (seed it
   in the test fixture so a `Get` call returns bytes — if the ready-
   fixture only populates the DB without seeding storage, the handler
   500s in test for a different reason).

A future refactor that "simplifies" by removing the mirror call will
fail assertion (1) immediately — no live spend needed to catch it.

**When a verified I2V model exists in the catalog**, the regression
test can temporarily flip `cinematicModels[i].Verified = true` for ONE
entry (restored on `defer`) so `chooseCinematicModel` picks it and the
handler reaches the mirror code path. Reverting the flag in defer keeps
other tests seeing the real catalog.

## Temporal client interface — grow it with SignalWorkflow

A new vendor-rendered kind with cancel/webhook signaling REQUIRES
`SignalWorkflow(ctx, workflowID, runID, signalName, arg) error` on the
`temporalClient` interface. Grow all three: the interface in
`apps/api/main.go`, the `realTemporal` adapter wrapping `c.SignalWorkflow`,
AND the `fakeTemporal` test stub (returning `nil`) — or `go test ./...`
in `apps/api` fails with a 'does not implement temporalClient' compile
error on the first test file that uses the fake.

## Higgsfield safety filter: name/prompt rejections

Seedance 2.0 (and Higgsfield's other T2V models) run a content-safety
filter that rejects submits with `error = "This request was blocked
due to potential copyright restrictions. Please try a different prompt
or reference media."` on the `/jobs/<id>` status endpoint. The submit
itself returns 202 cleanly — the block arrives at the status check
~3–10 s later.

**Triggers seen in practice:**

- Honorific + place-name titles that read like public figures or
  pageant titles (`"Mr. Africa"`, `"Miss <country>"`). The filter does
  not distinguish between a user-chosen influencer name and a real
  pageant/public-figure likeness.
- Real celebrity, politician, or trademarked-character names, with or
  without a reference image.
- Prompts that mention a specific real person by name alongside a
  photorealistic style request.
- Reference images that match a known public face or copyrighted
  character even when the prompt is innocuous.

**Recovery.** No code fix — the user edits the influencer name or the
prompt and retries. For an influencer-video kind that stamps the
influencer name into the prompt (`"introductory video of <name> ..."`),
edit the influencer first; retrying with the same name hits the same
block.

**Diagnostic rule.** Vendor rejection messages MUST reach the UI's
failed version tile (see render-lifecycle.md — "Surface the vendor's
rejection message"). If they don't, the user retries forever with the
same prompt and no sign of why. The agent's first diagnostic step on
`WORKFLOW_FAILED: cinematic: vendor reported failure: ...` is to pull
`content.renders.error_message` and read it — half the "the pipeline
is broken" reports are actually a one-line vendor block that would be
obvious to the user if the UI showed it.

## Cancel path rewiring: look up workflow_id, don't log a TODO

`handleCancelRender` has historically logged `"render cancel requested
(temporal signal not wired)"` and done nothing. When adding a kind whose
vendor must receive an explicit cancel ('Cancel must reach the API;
stopping polling alone does not cancel a generation'), replace that log
with a goroutine that reads `workflow_id` from the render row via
`s.db.GetRender(ctx, workspaceID, renderID)` and calls
`s.temporal.SignalWorkflow(ctx, workflowID, "", "<kind>.cancel", ...)`.
Other kinds' workflows ignore the unknown signal, so this change is
safe for every kind.

## Pricing wire: thread the per-kind settings into the quote request

The generic `handleRenderProject` quotes with `DurationSecs: len(scenes)*4`
and no tier field — fine for Remotion kinds, wrong for a vendor-rendered
kind that reads duration + model tier from `project.settings.<kind>`. In
the render-dispatch handler, re-load the project, pull
`settings[kind]["durationSec"]` + `settings[kind]["modelTier"]`, and
pass them explicitly into `pricing.Compute`:

```go
if pr.Kind == "<kind>" && s.db != nil {
    proj, _ := s.db.GetProject(ctx, workspaceID, pr.ID)
    cs, _ := proj.Settings["<kind>"].(map[string]any)
    tier, _ := cs["modelTier"].(string)
    if d, ok := cs["durationSec"].(float64); ok { durationSecs = int64(d) }
    // then: pricing.Compute(QuoteRequest{..., CinematicModelTier: tier, DurationSecs: durationSecs})
}
```

Without this, the user is quoted for a Remotion-style fake-4-s/scene
render and billed for a 10-second 4k vendor render, with no line item
naming the discrepancy.

## Scoping a new vendor-backed feature: read the vendor's OpenAPI first (zero spend)

Before promising a feature that mirrors a vendor's own product (e.g. an
"AI influencer" modelled on the vendor's app), fetch the vendor's machine-
readable spec (`https://docs.higgsfield.ai/docs/openapi.json`, linked from
`/docs/llms.txt`) and list its paths + request schemas with a short Python
script. The vendor's *app* routinely ships capabilities (identity training,
motion transfer, character builders) that the public *API* does not
expose; the spec is the only honest source for what we can build. Record
the gap in the plan and degrade explicitly (e.g. reuse the chosen portrait
as the reference image on every clip) rather than assuming parity.

What the Higgsfield spec exposed when checked: one image endpoint
(`higgsfield-ai/soul/standard`: `prompt`, `num_images` 1-4, `resolution`
2K|4K, `aspect_ratio`), image-to-video endpoints (Kling, Hailuo) taking
`prompt` + `image_url`, and a shared status envelope with `images[]`,
`video`, `audio`. No identity-training or motion-control endpoint.

Adapter traps this surfaced (check before building on the existing client):

- **Image-to-video submit body uses the JSON key `image_url`, not
  `reference_image`.** Every Higgsfield image-to-video endpoint in the
  public spec — Kling v2.5-turbo pro + standard, Minimax Hailuo 2.3
  standard — declares `image_url` as a required top-level field; the
  vendor 400s with `'image_url' is a required property` otherwise.
  Text-to-video endpoints (Seedance 2.0) don't read the field at all,
  so one `submitBody` struct with the correct JSON tag and `omitempty`
  serves BOTH paths cleanly — the field name is fixed, the Go field name
  is not:
  ```go
  type submitBody struct {
      Prompt   string `json:"prompt"`
      // ...
      ImageURL string `json:"image_url,omitempty"`  // <- JSON key is fixed; renaming the Go field is fine, renaming the tag breaks every I2V submit
  }
  ```
  Reference-ARRAY endpoints (Seedance 2.0 reference-to-video) take
  `image_urls: []string` — different shape; add a per-model code path
  when a kind that uses that endpoint ships. Pin the submit body with a
  test that POSTs an I2V request through a `httptest` server and asserts
  THREE things: `body["image_url"]` carries the URL; `body["reference_image"]`
  is ABSENT (regression trap for the old name); the raw request bytes
  contain the literal `"image_url"` substring — the raw-bytes check
  catches a future refactor that renames the Go field but forgets to
  update the JSON tag, which the first two assertions would miss
  (Go would send the right value under the wrong key).
- `pollResp` only decodes `video.url`; an image job returns `images[]`, so
  the poll would report "completed with empty video URL". Image kinds need
  their own poll decode.
- `ImageGen` in `aigw` is a 1x1-PNG placeholder (`IMAGE_GEN_REAL_ADAPTER`);
  a real image adapter is new work, and `ImageGenRequest` returns bytes,
  not URLs, so it does not fit an async vendor job as-is.
- Image endpoints are not video models: never list them in the video model
  registry (a past attempt failed at poll for exactly this reason).

Model/vendor choice stays server-side (`chooseCinematicModel`-style
selection); registries are never serialised to the web app.

## Two-step preview→promote handler lifecycle (N candidates, user picks one)

Some vendor surfaces are two-call: step 1 returns N candidate artefacts
(ElevenLabs Voice Design: 3 preview MP3s + ephemeral `generated_voice_id`;
variant image generators: K candidate images), step 2 commits one of them
(`create-voice-from-preview`, upscale/finalize). The handler shape that
keeps credits honest and the UI non-technical:

- **Reserve credits BEFORE step 1, not between step 1 and step 2.** Step 1
  is already a paid vendor call; a reservation gated only at step 2 charges
  nothing when the user previews and bails. Flat round-trip pricing kind
  (`Kind<X>Voice`, `Kind<X>Variant`) covers both calls.
- **Stash candidates server-side keyed by opaque ids.** Shape:
  `type pending<X> struct { workspaceID, ownerID, generatedID, description, sampleKey, reservationID string }`
  held in a `state.<x>Previews map[string]pending<X>` under `state.mu`. The
  stash key is what the UI sees (`"vp_" + ownerID + "_" + generatedID` works
  — unguessable without owning the influencer, cheap to look up). The vendor's
  own `generated_voice_id` NEVER leaves the server.
- **`consumePreview(id)` deletes under lock before calling the vendor.** A
  consume-then-promote atomic avoids a double-settle if the user hammers
  Save on the SAME preview: the second request finds no entry and 400s
  plainly. Return `(pending<X>, bool)`; the caller validates
  `pending.workspaceID == principal.WorkspaceID` AND `pending.ownerID == URL id`
  before trusting it — the stash is process-global, so cross-tenant/
  cross-owner guard happens on consume.
- **After a successful promote, DROP every sibling stash for the owner.**
  All N candidates from one step-1 call share ONE `reservationID` (the
  single flat round-trip hold). `consumePreview` only removes the picked
  entry; the N-1 siblings remain addressable, each still pointing at the
  now-settled reservation. A scripted caller POSTs promote with each
  sibling id in turn: `PromoteVoicePreview` runs on every one (one
  vendor slot consumed each time), `CreateCharacter` + `SetInfluencerCharacter`
  overwrite the previous linkage (orphaning the earlier character row),
  `settleHold` is a no-op at the ledger. Net: user pays once, vendor
  slot + local row consumed up to N times, N-1 rows orphaned.

  The fix is a ledger-free sibling delete AFTER the credit is settled
  (releasing again would be a no-op but produces log noise on genuine
  failures). Pattern:

  ```go
  // After settleHold / release-on-pricing-broke.
  s.dropPreviewsForOwner(owner.ID)  // delete-only, no releaseHold calls
  ```

  Pin with a test that promotes vp_A (expect 200), then posts promote
  with vp_B (expect 400) — the sibling stash must be gone. The naive
  implementation returns 200 on the second call.
- **Ledger idempotency is not a handler-level safety net.** `settleHold`
  and `releaseHold` on `services/ledger` are idempotent: a second call
  against the same reservation is a no-op, not an error. This means a
  handler bug that lets two code paths settle the same reservation does
  NOT surface as a ledger failure — it surfaces as a silent over-
  consumption of the vendor resource backing that reservation. Prevent
  double-use at the stash layer (see sibling-drop above); never rely on
  the ledger to reject.
- **Supersede releases prior holds on re-step-1, deduping by reservationID.**
  When a new previews call arrives for the same owning entity, release
  every stashed entry's `reservationID` with
  `s.releaseHold(..., "<x> preview superseded")` and delete from the
  map. Dedupe the reservation ids before releasing: all N siblings
  share one reservation, so a naive loop calls `releaseHold` N times.
  The ledger is idempotent but each extra call fires a `slog.Warn` on a
  genuine release failure — N redundant warn lines per supersede. The
  dedupe set lives inside the lock.

  ```go
  seen := map[string]bool{}
  for id, p := range s.<x>Previews {
      if p.ownerID == ownerID {
          if !seen[p.reservationID] {
              seen[p.reservationID] = true
              s.releaseHold(p.reservationID, "<x> preview superseded")
          }
          delete(s.<x>Previews, id)
      }
  }
  ```

  Without supersede, a user clicking "Try different previews" three
  times holds three reservations until each 24h-expires; the ledger
  shows triple-locked funds the user never spent.
- **Promote failure after character/row commit is NOT a rollback.** If
  `CreateCharacter` succeeds but `SetInfluencerCharacter`/`UpdateCharacterSample`
  fails, the character row is orphaned (unlinked). Do NOT delete it — the
  vendor-side permanent voice slot was already consumed by the promote
  call, and deleting the local row loses the only pointer to it. Log the
  vendor id and the local character id in `slog.Error` so an operator
  can backfill with a direct `UPDATE content.influencers SET character_id = ...`.
- **Preview MP3s/bytes live in the PUBLIC bucket** under a per-owner
  deterministic key (`influencers/<ws>/<id>/voice/preview-<i>-<voiceId>.mp3`).
  Deterministic so a re-run under the same `generated_voice_id` overwrites
  rather than orphaning; per-owner so an unauthenticated reader of the
  bucket can at least not browse by random id. The URL returned to the
  UI points at that bucket — do NOT serve the vendor's own CDN URL
  (expires, leaks the vendor's internal object key).
- **`DELETE` unlinks, does NOT un-promote.** Deleting the voice from an
  influencer calls `ClearInfluencerCharacter` only; the `content.characters`
  row survives (voices stay reusable in Cast) and the ElevenLabs custom-
  voice slot stays consumed (operator cleans up out-of-band). Also drop
  any still-stashed previews for that owner so a stale UI can't promote
  after the user removed the voice.

Pin with handler tests: happy path (3 previews, correct balance held),
blocked-on-not-ready (400 before vendor is called, no hold), promote
unknown previewId (400), rate-limiter-before-body-parse (broken JSON on
the second call must 429 not 400), vendor-500-sanitised (hostile body
does not reach the response, hold is released), and delete-keeps-
character (character row survives after unlink).

## Mirror-kind pricing: flat base + delegate the surcharge

Some kinds are user-facing wrappers around another kind's compute
(`influencer-video` dispatches an image-to-video cinematic job; a
`series-episode` kind might wrap `motion-graphics`). Price them as
`base + delegate_surcharge` rather than inventing a parallel rate table:

```go
if r.Kind == Kind<Wrapper> {
    tier := r.CinematicModelTier
    if tier == "" { tier = "hd" }
    rate, ok := cinematicTierSurcharge[tier]
    if !ok { return nil, errs.New(errs.CodeBadRequest, "unknown ... tier: "+tier) }
    amt := (r.DurationSecs * rate) / 10
    if r.DurationSecs > 0 && amt < 1 { amt = 1 }
    items = append(items, LineItem{Label: "<wrapper>:"+tier, Units: r.DurationSecs, Rate: rate, Amount: amt})
    return &Quote{Total: base + amt, Version: Version, LineItems: items}, nil
}
```

Pin parity with a test: `Compute(wrapper, 6s, hd).Total == Compute(delegate, 6s, hd).Total`.
The test exists so a future rate drift in one table doesn't silently
make the wrapper cheaper or more expensive than the thing it dispatches
— users paying different prices for the same vendor work depending on
which handler dispatched it is the shape of bug this catches.

## Non-fatal post-create backlink stamp

When a cross-table backlink is nice-to-have but not essential (e.g.
`content.projects.source_influencer_id` so the influencer profile can
list its own projects without joining through assets), stamp it in a
separate `UPDATE` after `CreateProjectWithSettings` returns, and treat
failure as log-and-continue:

```go
dbProj, derr := s.db.CreateProjectWithSettings(ctx, ws, kind, title, scenes, settings)
if derr != nil { /* ...fatal... */ }
if lerr := s.db.SetProjectSourceInfluencer(ctx, ws, dbProj.ID, infID); lerr != nil {
    slog.Warn("<x> video: SetProjectSourceInfluencer failed",
        "projectId", dbProj.ID, "influencerId", infID, "err", lerr)
}
```

The log line carries both ids so an operator can backfill the one row
by hand without a schema migration. Doing this in-transaction would
couple the backlink's success to the project creation — a transient FK
contention on the backlink would then kill a project the user has
already paid for and that is otherwise usable in the Library. The
backlink SETTER is workspace-scoped so a cross-tenant project id
silently no-ops rather than linking the wrong row.
