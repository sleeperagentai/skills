# packages/compositions/src/compositions/MotionGraphics — layout & overlay rules

Rules that only surface when you look at the rendered frames. Composition unit tests exercise metadata (durationInFrames, dimensions) and prop threading but not visual layout — a composition can pass every test with a presenter flush to the left edge, a watermark inside the caption box, or captions timing to evenly-distributed placeholders instead of real syllables.

## Presenter positioning: `position` is for two-people, `centered` for one-narrator

The `Presenter` primitive at `packages/compositions/src/primitives/Presenter.tsx` takes `position: 'left' | 'right'` — an anchor to `left: width * 0.04` or `right: width * 0.04` (a side gutter). This is correct for two-people mode where the active speaker sits opposite the reacting speaker. In one-narrator layouts it sinks the single sprite to a frame corner and leaves the other half of the frame empty.

The primitive carries a `centered?: boolean` prop that overrides the side anchor with `left: 50%; marginLeft: -spriteSize / 2`. The MotionGraphics composition passes `centered={otherPresenter == null}` at the callsite so single-presenter turns center the sprite and two-people turns keep the side anchors. When adding a new composition or new presenter callsite, mirror the same `centered={otherPresenter == null}` pattern — a bare `<Presenter position="left" />` in a solo layout is a shipped design regression that vision-verify catches immediately and no test does.

Vertical position lives on the primitive too: `bottom: height * 0.38` (raised from an earlier `height * 0.12`) so the sprite sits near vertical center rather than just above the captions. Do not tune this per-composition unless the composition is deliberately shifting focus (e.g. a title-card variant that wants the title at eye-level).

## Watermark: anchor to `safeZone.bottom`, not raw pixels

The watermark overlay is painted directly by the composition when `props.watermark === true`:

```tsx
{props.watermark === true && (
  <div style={{
    position: "absolute",
    right: Math.round(short * 0.03),
    // Sit ABOVE the caption safe-zone, not inside it.
    bottom: safeZone.bottom + Math.round(short * 0.02),
    transform: "rotate(-8deg)",
    transformOrigin: "100% 100%",
    opacity: 0.35,
    color: props.theme.palette.fg,
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
    fontSize: 22, fontWeight: 600, letterSpacing: 0.5,
    pointerEvents: "none",
    textShadow: "0 1px 2px rgba(0,0,0,0.6)",
  }}>OpenStudio</div>
)}
```

A naive `bottom: short * 0.03` places the glyph INSIDE the caption safe-zone (~22px up from the frame edge on 720×1280) and it overlaps whatever caption is drawn at that moment — the rotation and opacity make it look intentional at first glance but the reserved caption band is per-aspect (`SAFE_ZONE_BY_ASPECT`) and non-trivially large. Every overlay that positions relative to the frame edge (progress bar, badge, watermark, source citation) must add `safeZone.bottom` (or `safeZone.top`) to the raw offset, not use raw px. Same for horizontal safe-zones if the aspect ratio has them.

Worker-render decides the boolean value of `watermark` per plan (`plan === 'free'` → true). The composition's job is only to paint it when the prop says so — never gate on plan inside the composition; that couples the render layer to billing state.

## Verifying composition changes: extract frames, view with vision

`ffprobe` on the output MP4 only confirms shape (codec, dimensions, duration). It cannot see whether the presenter is centered or the watermark overlaps captions. After any composition edit, render one real MP4 and pull 3 frames at different time offsets:

```bash
ffmpeg -y -i /tmp/e2e-final.mp4 \
  -vf 'select=eq(n\,20)+eq(n\,100)+eq(n\,170)' \
  -vsync vfr /tmp/e2e-final-f-%d.png
```

Offsets `20, 100, 170` sample early / mid / late frames on a ~200-frame render; adjust for longer clips. Feed each frame to `vision_analyze` (or eyeball in Preview) with a targeted question — "is the presenter centered horizontally? is the watermark visible in bottom-right without overlapping the caption box?" A composition change that passed `go build` + `tsc --noEmit` can still ship a broken layout that no automated test catches; the extracted-frame pass is the only stopgap until Remotion snapshot testing lands in the repo.

## Determinism tests: compare PNG frames, never MP4 bytes or decoded MP4 frames

A "same input → identical output" check for a composition must hash frames rendered to PNG (`renderStill` at frame N, or `renderFrames` output) across two runs. H.264 is lossy and its output bytes aren't stable from run to run, so a frame decoded from the MP4 never equals the PNG still of the same frame, and two visually identical renders can produce different MP4 hashes. The same rule applies to "the approved still is identical to that frame in the final video": compare the still against that frame's PNG from the render, before encoding. For the render to be pure:
- no `Math.random()` without a seeded RNG (`random(seed)` from `remotion`);
- no CSS transitions or animations;
- no timers and no wall-clock reads;
- all motion derives from `useCurrentFrame()`.

## Caption timings depend on the ASR/Align chain, not the composition

The `<Captions>` primitive takes `wordTimings: [{word, startMs, endMs}]` and highlights the active word per-frame from `useCurrentFrame()`. When the ASR provider is `fake`, `wordTimings` is empty/placeholder and the composition falls back to distributing words evenly across `durationMs` — the highlight visibly drifts against the audio. When the provider is `local:whisper.cpp` (or cloud OpenAI Whisper), timings come from real transcription and the highlight lands on the actual syllable being spoken. If a caption highlight looks off, the fix is in `services/ai-gateway/localwhisper/` or `services/ai-gateway/align/`, not in the composition. Check the factory startup log first: `aigw: ASR=fake` vs `aigw: ASR=local:whisper.cpp model=...` — the difference is visible in the rendered frame within one second of playback.

## `interpolate` demands strictly-increasing inputs; whisper timings do not guarantee that

Remotion's `interpolate(nowMs, [t0, t1, t2, ...], [v0, v1, v2, ...], ...)` throws a `SymbolicateableError: inputRange must be strictly monotonically increasing but got [...]` the moment two adjacent times tie or reverse. This is a HARD render failure — the workflow ends up stuck in `stage: 'render'` with the error visible only in the worker-render log, not the API response.

Two failure sources that both hit within one composition edit:

1. **Multi-anchor fade windows collapse on short chunks.** A chunk-fade shape like `[chunkStart - 60, chunkStart, enterEndMs, exitStartMs, chunkEnd, chunkEnd + 60]` looks safe algebraically but breaks when the chunk is shorter than `enterFade + exitFade` (single-word ~200ms chunks make `enterEndMs > exitStartMs`). Guard the fade constants against the actual chunk duration:

   ```ts
   const chunkDur = Math.max(1, chunkEnd - chunkStart);
   const enterFade = Math.min(120, chunkDur * 0.4);
   const exitFade  = Math.min(80, chunkDur * 0.3);
   const enterEndMs  = chunkStart + enterFade;
   const exitStartMs = Math.max(enterEndMs + 1, chunkEnd - exitFade);
   ```

2. **Whisper.cpp word timings can be non-monotonic across word boundaries.** Real whisper output sometimes emits `endMs` for word N that overlaps or precedes `startMs` for word N+1 (observed pairs like `... 7140, 7120 ...` in the input range). Any interpolation that spans multiple word timings (per-word scale bump, chunk-boundary detection) must guard the input range itself, not just the fade constants. Take `Math.max(prevEnd + 1, thisStart)` before feeding a word pair into `interpolate`.

Symptom that this is what happened: worker-render log shows `SymbolicateableError: inputRange must be strictly monotonically increasing but got [...]` with a stack pointing into the composition's `interpolate` call and the render workflow retries indefinitely (Temporal default retry policy) instead of failing fast. Also see the retry-policy invariant in SKILL.md — activities that hit this need a bounded `MaximumAttempts`.

## Composition bundle staleness after edits under `packages/compositions/`

`apps/worker-render` runs Remotion's `bundle()` per render request, which builds its own webpack bundle from `packages/compositions/src/`. The bundle is cached in `packages/compositions/node_modules/.cache/webpack/remotion-production-<version>/`. When you edit a composition primitive (e.g. `Captions.tsx`), tsx-watch reloads `apps/worker-render/src/worker.ts` but does NOT invalidate that Remotion bundle cache — the NEXT render still uses the OLD compiled composition. Debug logs (`console.log` inside a composition primitive) surface in the worker-render stdout when a new bundle is picked up; if you're seeing OLD log lines that reference OLD content while the file on disk has been updated, the bundle is stale.

Force a clean rebuild when a composition edit isn't landing:

```bash
pkill -f 'apps/worker-render'
rm -rf packages/compositions/node_modules/.cache
cd apps/worker-render && pnpm dev > /tmp/os-logs/worker-render.log 2>&1  # via terminal(background=true)
```

The cache directory can also be watched with `ls -la` to confirm it repopulated. Do NOT trust `git status` or file mtimes on `Captions.tsx` as evidence the composition change is live — those only prove the SOURCE is updated, not that the render pipeline is reading it.

## Full-frame overlay components own their own `<AbsoluteFill>` — do NOT wrap them in a parent flex container

Remotion's `<AbsoluteFill>` with `justifyContent: flex-end + alignItems: center` COLLAPSES a child that returns a plain `<div>` with padding + background + border to zero height, even when every prop (opacity, color, background) is set. The child mounts, its `console.log` fires, `interpolate` returns real values — but the outer flex context never gives the shell any layout box, so the rendered pixels are empty. This is the failure mode where the composition compiles, tests pass, the primitive's log lines confirm it's running with correct props, and the frames still show a blank caption band.

The fix is structural, not stylistic: full-frame overlay components (Captions, watermark banners, chapter markers, presenter nameplates) must return their OWN `<AbsoluteFill>` and self-position with `justifyContent`/`alignItems`/`padding`, not rely on a parent to place them. The caller in the composition (`MotionGraphics.tsx`) passes props and nothing else — no wrapping AbsoluteFill, no flex parent:

```tsx
// WRONG — child returns a <div>, parent flex context collapses it invisibly:
{props.captionsOn && (
  <AbsoluteFill style={{ justifyContent: 'flex-end', alignItems: 'center', paddingBottom: 51 }}>
    <Captions text={...} wordTimings={...} />
  </AbsoluteFill>
)}

// RIGHT — Captions owns its own AbsoluteFill and positions itself:
{props.captionsOn && <Captions text={...} wordTimings={...} style={...} />}

// ... and inside Captions.tsx:
return (
  <AbsoluteFill style={{ justifyContent: 'flex-end', alignItems: 'center', paddingBottom: 100 }}>
    <CaptionShell>{...}</CaptionShell>
  </AbsoluteFill>
);
```

Symptom of the wrong shape: the DEBUG-shim red bar (see next section) does show up when the child is a `position: absolute` `<div>` with fixed coords, but a normal styled shell inside the same wrapper doesn't. That contrast is the tell — absolute positioning bypasses the flex parent's box calculation, so a hard-coded `position: absolute; top: 100px` shows through while the shell-based render disappears. Do not "fix" it by hard-coding absolute positions in the overlay; move the positioning ownership into the child component and drop the wrapping AbsoluteFill in the composition.

The same rule applies to any Remotion primitive that wraps children in a flex `<AbsoluteFill>` (which is most of them): the child either returns an absolutely-positioned element that self-lays-out, or it returns its own `<AbsoluteFill>` and takes over positioning. A child returning a plain `<div>` inside a flex `<AbsoluteFill>` parent is the collapse trap.

## Per-scene b-roll: consuming a VideoGen clip as the scene background

The default MotionGraphics composition draws a single flat theme colour behind the presenter for every turn — visually identical whether the script is about pastries or particle physics. To make the visuals track the narration, extend `MotionGraphicsTurn` with an optional `visualClipUrl?: string` and `presenterMode?: 'hide' | 'corner-sm' | 'corner-lg'`. When set, the composition swaps the flat background for a real MP4 clip (typically a Higgsfield / VideoGen output uploaded to MinIO) and repositions the presenter as a docked talking head. When absent, the turn renders exactly like today's fallback layout — this preserves backwards compatibility for the renders that predate the AI Director wiring.

Use `<OffthreadVideo>` from Remotion, not `<Video>`, for the clip source. `OffthreadVideo` decodes the stream on a worker so a long clip (5-10s at 720p) does not stall the render frame loop; `Video` blocks per-frame and can push a single motion-graphics render past the workflow's activity timeout when three or four turns each carry a clip. `objectFit: 'cover'` fills the frame at any aspect ratio; `muted` is mandatory because narration audio is already shipped through the composition's `<Audio>` node and the clip's own soundtrack would double-layer.

Unpredictable footage needs a legibility overlay — a top+bottom vignette gradient reserves the caption and watermark bands without darkening the mid-frame content:

```tsx
<AbsoluteFill style={{
  background: 'linear-gradient(180deg, rgba(0,0,0,0.15) 0%, rgba(0,0,0,0) 30%, rgba(0,0,0,0) 60%, rgba(0,0,0,0.55) 100%)',
  pointerEvents: 'none',
}} />
```

This matters more than it sounds: without the bottom gradient a bright scene clip (sunlit espresso pour, snow, chrome) blows out the caption pill and the accent-underline stops reading against a busy background — a rendered layout regression the extracted-frame vision pass catches immediately.

### PresenterCorner — talking-head docked over live footage

When a `visualClipUrl` is set, the inline centred `<Presenter>` is the wrong composition — it covers the clip. Ship a `PresenterCorner` variant that:

- Docks bottom-right with `right: short * 0.03; bottom: short * 0.03`.
- Sizes at `short * 0.22` for `corner-sm`, `short * 0.34` for `corner-lg`.
- Reuses the same `speakingFrames` window as the inline presenter so mouth-open/closed lip-sync stays intact (alternate open/closed sprite every 3 frames while `frame >= speakingFrames.start && frame < speakingFrames.end`).
- Wraps the sprite in a `borderRadius: '50%'` circle with a 3px white border and the presenter's `nameplateColor` behind the sprite (matches the roundel style on `/cast`).

The gate in `MotionGraphics.tsx` is a three-way pick, not two nested conditionals:

```tsx
const brollMode = visualClipUrl ? t.presenterMode ?? 'corner-sm' : 'hide';
const showPresenterInline = !visualClipUrl && hasAnyPresenter;
const showPresenterCorner = !!visualClipUrl && brollMode !== 'hide' && hasAnyPresenter;
```

`showPresenterInline` and `showPresenterCorner` are mutually exclusive — a naive `{presenter && <Presenter />}` that stays after adding the corner variant double-composites the presenter (once centred, once docked) and the extracted-frame verification catches it.

### Backwards compatibility contract

Older turns without `visualClipUrl` render exactly like the pre-clip composition: no vignette, no OffthreadVideo, inline centred presenter, flat theme background. Ship the composition change (V2 layout) as a superset — the turns that carry `visualClipUrl` opt into the new rendering; turns that don't stay on the classic path. This means the composition can land before the api-side Storyboard schema and the worker-core VideoGen activity that populate the field — no coordinated deploy needed.

### Higgsfield seedance-2.0 vendor quirks

The default text-to-video model (`HIGGSFIELD_MODEL` unset → `bytedance/seedance-2.0/text-to-video`) has two request-body constraints that neither the schema nor `go test` catches:

- **`duration` minimum is 4 seconds.** Requests with `duration: 2` or `3` are rejected with HTTP 400 `"duration: N is less than the minimum of 4"`. Small local LLMs (Qwen2.5-3B) routinely emit 2-3s scenes for punchy narration like `"Coffee."` or `"Focus. Energy. Ritual."`. Clamp at the workflow dispatch (`if durSec < 4 { durSec = 4 }` before `ExecuteActivity(HiggsfieldGenerateActivity, ...)`); the composition trims the clip at the audio-derived duration so the final video output is unchanged. Also warn the Director prompt to keep broll scenes ≥4s so the LLM stops producing them at all.
- **`aspect_ratio` uses colon notation, not `x`.** OpenStudio uses `9x16` throughout the composition, schemas and DB; Higgsfield rejects with HTTP 400 `"aspect_ratio: '9x16' is not one of ['16:9', '4:3', '1:1', '3:4', '9:16', '21:9']"`. Map at the adapter boundary (`services/ai-gateway/higgsfield/higgsfield.go`, private `normalizeAspectRatio` helper), not at the workflow — the workflow shouldn't know about vendor formats. `4x5` maps to Higgsfield's `3:4` (nearest match — they have no 4:5). See the general adapter-boundary normalisation rule in SKILL.md.

A third failure mode is orthogonal to the request shape: HTTP 403 `{"detail":"not_enough_credits"}` when the operator's Higgsfield balance is empty. This is not a code bug — a top-up fixes it — but the WORKFLOW must degrade gracefully rather than failing the render. See the graceful-degradation invariant in SKILL.md; concretely for MotionGraphics, the workflow catches `brollErr != nil` after the fan-out, logs it, and sets `in.MotionGraphics.Storyboard = nil` so the render input carries no `visualClipUrl` on any turn — the composition then falls through to the classic presenter-only layout. Users still get a video; they just don't get b-roll on the scenes that would have had it.

## Rendering catalog previews via the real pipeline

Look / template preview MP4s (the video that plays in each `LookCard`) are best generated by running the real motion-graphics render pipeline once per template, uploading the output to `openstudio-public/templates/tpl_<kind>_<name>.mp4` — the path the templates catalog already references in `previewUrl`. This ensures every preview shows the actual title-card animation, caption chrome, and transition set the user will get, not a stylised mockup that drifts from reality.

Pattern:

1. Fire one render per template with `presenters: []` (no presenter distracts from the Look's own chrome), a short canned narration (~10 words that showcases the caption style), and `captions.enabled = true`.
2. Cap the API `Idempotency-Key` per template so re-runs are safe.
3. **Pace the submits.** The per-workspace rate limiter on `POST /api/v1/motion-graphics/projects` caps at ~5 concurrent submits and returns 429 after that. Loop with a 1-2s sleep between submits AND a per-attempt 429-retry with exponential backoff (`12s, 24s, 36s, ...` — the limit is a fixed-window, waiting a full window frees the next slot):

   ```python
   for attempt in range(6):
       try:
           post_project(...)
           break
       except HTTPError as e:
           if e.code == 429 and attempt < 5:
               time.sleep(12 * (attempt + 1))
               continue
           raise
   time.sleep(1.2)  # gentle pacing between successful submits
   ```

4. Poll each render id until `stage in {done, failed}`. The 429 retry pattern applies to `GET /renders/{id}` too when polling in a tight loop.
5. Download + `mc cp local/openstudio-public/templates/<template_id>.mp4`. The client renders the preview via `<video muted playsInline loop preload="metadata">` — hover-to-play — so a ~2-3s clip is plenty and keeps the MinIO storage cheap.

Do NOT hand-author preview MP4s or render them through a separate Remotion path — the whole point is that a Look's preview updates whenever the composition, palette, or caption style updates. If the pipeline shifts (new transition set, retuned caption font size), re-run the batch and the preview grid stays truthful without any code change.

## Diagnosing "my component isn't mounting" in a composition

When a composition primitive appears to be missing from the rendered pixels but its parent conditional is definitely true (`props.captionsOn === true`, wordTimings present, etc.), the fastest way to distinguish "never mounts" from "mounts but renders invisibly" is a guaranteed-visible short-circuit at the top of the component's render:

```tsx
const _debug_show_all = true;   // TEMP — remove before commit
if (_debug_show_all) {
  return <div style={{ background: 'red', color: 'white', padding: 40, fontSize: 80 }}>DEBUG</div>;
}
```

A visible red DEBUG box in the frame proves the component is mounting and the parent's positioning/opacity/clip is fine — the bug is in the component's own draw logic. No DEBUG box proves the component is not mounting — the bug is upstream (parent conditional, prop plumbing, bundle staleness). Pair with a `console.log` at the very first line inside the component so the worker-render stdout confirms mount events even if a downstream ancestor clips the output. Remove both before committing — the shim is a diagnostic, not a fallback.

Complementary check: a `console.log` INSIDE the parent's conditional block (rendered as `{(() => { console.log(...); return null; })()}`) surfaces the actual runtime prop values (`captionsOn`, presence of `wordTimings`, chunk counts) so you don't have to guess at what the render input carried. Use these to prove the conditional path is being taken before assuming the child component is broken.
