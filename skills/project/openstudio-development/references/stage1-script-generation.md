# Stage 1 — script generation

Persona steering, length, formatting and streaming. Read before touching the
stage-1 prompt, `script_expand.go`, `storyboardBody`, `CleanForDisplay`, or
SSE route registration.

## Persona steering

**`GetCharacter` cannot see public characters — use `ResolveCharacter` in the pipeline.** `GetCharacter` requires an exact `workspace_id` match, which is right for editing but 404s on all six public voice-narrators and every cartoon presenter (`workspace_id IS NULL`). `store.ResolveCharacter(ctx, workspaceID, id)` accepts the workspace's own characters OR public ones and returns `CodeNotFound` for everything else — including another tenant's character. **Never 403 for a cross-tenant id:** distinguishing "forbidden" from "missing" confirms which ids exist in other tenants. It also selects `short_description`/`description`, which `GetCharacter` omits and persona injection needs.

**A persona only works if it carries writing INSTRUCTIONS, and the proof is a 3-way diff against the real model.** "Write as Pip. Pip is playful." yields neutral narration with the word "playful" in it. Migration 00022's `persona_prompt`s are imperative ("simple words and genuine wonder, plenty of 'did you know', keep sentences short"), and running one topic through the live local LLM three ways — no character / Pip / Bellweather — showed the difference clearly (Pip emitted "Did you know?", Bellweather "the heart of a planet... a planet's symphony"). Do that comparison when touching prompt construction: a test asserting the id round-trips would pass against an implementation that stores the id and ignores it.

Two construction rules, both already paid for here:

- **Prose section labels, never XML tags.** `<persona>...</persona>` is echoed back verbatim by sub-7B local models, and local is the default provider on this machine.
- **"Write AS this character — do NOT describe them, do NOT mention their name."** Without the prohibition, models open by describing the persona. Even WITH it, Qwen2.5-3B produced "Pip wonders, 'How does this work?'" in the narration — so detect the leak (`characterNameLeaked`, word-boundary matched so "Cleo" misses "Cleopatra") and WARN. Do not auto-strip: a script whose topic legitimately is that name would be corrupted, and silently editing a user's generated text is worse than flagging it for a re-roll.

**Resolve credits inside the async goroutine, not the handler, on a sync-with-202-fallback endpoint.** `/live/scripts` returns 202 and keeps generating; settling in the handler would charge for work that has not finished and may still fail. The goroutine owns resolution for the path it completes. Also store a GENERIC message in `scripts.error_message` — the client reads that row back, so raw provider text must not land in it.

**On a sync/async-fallback endpoint, BOTH branches must persist the terminal row — not only the async one.** The 202-timeout path already called `SetScriptStatus(..., "done", body, scenes, storyboard, ...)` in its background goroutine; the 200-sync path returned the same data in the HTTP response but silently skipped persistence, so `content.scripts` stayed `status=queued, body=NULL, storyboard=NULL`. Downstream, stage 2's `buildMGRenderPayload` read the empty row, logged `script text is empty`, dropped the `MotionGraphics` payload, and the workflow's storyboard-gated branch (visuals seam / b-roll fan-out) silently short-circuited to presenter-only — with NO `Degraded` flag set, so the user got a stripped-down render with no in-band signal. Mirror the terminal `SetScriptStatus` call on EVERY completion path before `writeJSON`; log but do not fail the response on a persist error (the client already has the data; losing the row only hurts the next stage). Regression-test by asserting the row's final state (status, body length, storyboard presence) after a 200, not by trusting the response body alone. Same rule for any stage that chains stage-N → stage-N+1 via an id lookup: the DB row IS the hand-off contract, not the HTTP response.

**Repoint existing handler tests at the guarded wrapper, not the bare handler.** When `/live/scripts` moved behind `stageGuard`, the 10 existing tests still called `st.handleLiveScripts` directly and bypassed the entire safety chain. Pointing them at `st.handleLiveScriptsGuarded()` made them cover auth, rate limiting, body bounds and moderation for free — and immediately surfaced that the shared `/live` test state had no funded ledger.

## Length

Starting point: a 180-second request produced **104 words (23% of target)**
as one unbroken line of fragments. Five independent bugs, each sufficient
alone to cause the complaint.

**Telling a model "write N seconds" does nothing; state a WORD COUNT.**
150 wpm is the conversion (`wordsForSeconds`, `apps/api/script_length.go`).

**Prompting fixes STYLE, not LENGTH.** Even with an explicit word budget, a
per-scene budget and a failure warning in the prompt, Qwen2.5-3B still
delivered 104 words against a 450-word target. Small models cannot track a
running word count across a long structured output. Do not keep escalating
prompt language — it does not work.

**So length needs a second pass.** `apps/api/script_expand.go` measures,
then rewrites scene by scene ("make this paragraph N words"), which is the
kind of local task small models handle well. Rules learned the hard way:

- Reject any result **shorter** than the input — that is a failed pass, not
  an expansion.
- Reject anything over **3x** the request — rambling or prompt echo.
- Never alter scene **count, index, duration or visuals** — narration only,
  or the storyboard desyncs from its visuals.
- **Track a running total and stop once in band.** Expanding every scene
  regardless overshot to **154%**: each per-scene request overshoots a
  little (~87 words for 61 asked) and the error compounds across scenes.
- Bound the passes (2), respect cancellation, and leave the storyboard
  untouched on provider failure. A short script is a disappointment; a
  corrupted one is a bug.

**`MaxTokens` must scale with target duration.** A hardcoded budget (it was
1400 for every duration) truncates the storyboard mid-JSON, and the parser
keeps whatever arrived — a short script with **no error logged anywhere**.
This silent-truncation path is the hardest of these bugs to spot.

**Reject out-of-range durations, never clamp them.** Silently halving a
request bills for work the caller did not ask for. UI 15–180s, API ceiling
900s (15 min), with a test asserting the API ceiling exceeds the UI limit so
the wizard can never construct a request its own backend refuses.

## Formatting

**Separate scenes with a blank line, not a space.** `storyboardBody()` did
`strings.Join(parts, " ")`, which guaranteed the wall of text regardless of
model output. TTS also reads a paragraph break as a longer pause, so this
fixes pacing as well as readability.

**The narration IS the script body.** `parseDirectorOutput` preferred the
lead-in prose outside the `<STORYBOARD>` block whenever it was non-empty, so
a model emitting "Sure! Here's a storyboard..." had *that* become the body —
bypassing the paragraph join and bearing no relation to the scenes.

**Verify a doc comment before trusting it.** `CleanForDisplay` claimed it
"preserves paragraph breaks" while joining every line with a single `\n`
(`splitSpeakableLines` drops blank lines as structural). It silently undid
the paragraph fix at the very last step before display. Found only by
writing a test that asserted the comment was true. Treat comments as claims
to verify, not facts.

**Prompt style examples must be about an UNRELATED topic.** Tide examples in
the prompt had a tides script open with the prompt's own GOOD example
verbatim. Now bread making, with an explicit "copy the style, never the
subject, write about the requested topic only".

## Streaming

**Long-running SSE routes must be registered OUTSIDE `middleware.Timeout`.**
chi applies middleware only to routes registered after `r.Use` within a
group, so registration ORDER is the entire mechanism (`apps/api/main.go`,
pinned by `stream_timeout_test.go`).

A timeout on a streaming route gives the **worst possible failure mode**:
the client receives start + deltas then a dead connection, while the
handler's deliberately detached `genCtx` carries on and persists the result
correctly. The data looks perfect; only the user sees breakage. Symptom in
the log is `http: superfluous response.WriteHeader call from
middleware.Timeout`.

**Test SSE direct against `:4000`, not through the Next dev proxy**, when
terminal events go missing — it isolates proxy buffering from handler bugs.

**Never diagnose a missing SSE tail from how the client exited.** `EXIT=143`
is SIGTERM — i.e. *you* killed it, usually via your own `pkill` before
restarting the API — and it says nothing about delivery. Use evidence that
does not depend on the client at all: the handler writes `replace` before
`SetScriptStatus("done")`, so a `content.scripts` row at `status=done`
**proves** those frames were written server-side. Compare the row's
`updated_at` against when the client died; a client still connected for
minutes afterwards that received nothing was severed by an intermediary, not
by your kill. Check the exit code of any `curl` you are about to treat as
evidence — a self-inflicted SIGTERM is indistinguishable from a real drop in
the captured output alone.

**A long silent gap mid-stream needs keepalives.** The expansion pass is one
model call per scene — minutes of silence on local inference. Through the
Next proxy the client received 488 deltas then **nothing**: the handler
completed and persisted the script correctly, but the idle connection was
dropped before `replace`/`done`, so the client hung on a request that had
succeeded. Direct to `:4000` the same run was fine, which is how the
intermediary was identified. Any proxy, LB or CDN does this.

`sseKeepAlive` writes an SSE **comment** (`": keepalive"`) every 10s. A
comment is the SSE-native keepalive — clients ignore it by spec, so it needs
no client support (`apps/web/lib/sse.ts` already skips `:` lines). Two rules:
serialise writes through a mutex (keepalive + events share one
`ResponseWriter` across goroutines; without it the race detector reports 5
races, and a keepalive spliced mid-frame corrupts both), and cancel the
goroutine the instant the slow work returns so it cannot write to a
`ResponseWriter` whose handler has returned.

**Distinguish notice kinds client-side.** A `notice` with `stage=expanding`
means streaming WORKED and the server is now lengthening the script; a bare
`notice` means the provider cannot stream at all. Clearing a `streamed` flag
on the former makes a working stream report itself as non-streaming.

## Structured output from small local models

**Local sub-7B LLMs skip structured-output instructions no matter how the
prompt is worded — ship a prose fallback parser alongside the strict one.**
Cloud models follow `Return a JSON block wrapped in <SCENES>...</SCENES>`
reliably; CPU-friendly 3B-class models emit `Opening Scene: …` / `Scene 1: …`
prose instead roughly half the time, even with an inline example. If the
strict parser fails, do NOT collapse to a topic-only synth that discards
real model output — try a prose regex first. Pattern from `parseProseScenes`
in `apps/api/content.go`: case-insensitive line-anchored
`^\s*(opening\s+scene|closing\s+scene|scene\s+\d+)\s*[:\-.]\s*(.+)$`,
requiring **≥2 matches** before trusting the parse (one match fires on
unrelated text like `Scene 1: this is a great show` from prompt echo), then
distribute target duration evenly with the last scene absorbing the
remainder. Lock the shape with a test fed ACTUAL captured model output —
models drift, and a parser tuned to one output shape breaks silently on the
next swap.

The fallback chain, in order, each tier keying off the previous tier's
output so real model content survives as long as possible:
strict-parser → prose-parser → scenes-to-body-synth → topic-only synth.
Applies to any structured-output capability (turn lists, shot lists, chapter
markers).

**The scenes-to-body-synth tier matters more than it sounds.** Local models
sometimes emit a valid `<SCENES>` block with NO lead-in prose, especially
when the prompt is heavy on structural instructions. The strict parser then
succeeds on scenes but leaves the body empty, and the naive next step —
`if body == "" { body = synthNarration(sc) }` — throws away the real
per-scene text for topic-keyed filler. Instead join the scene texts into the
body (`synthBodyFromScenes`), one sentence per scene. Fall through to the
topic-only synth only when BOTH the structured and prose parses failed.
