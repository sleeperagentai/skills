# Claude-authored Remotion TSX seam (`services/visuals/tsx` + `apps/worker-render` sidecar)

> **Scheduled for deletion** in the last phase of the codegen series (ADR 0019). Do not iterate on its prompts or migrations. The one piece that survives is the AST gate (`services/visuals/tsx/astcheck/sidecar/tsx-check.mjs`), which the motion engine's per-beat scene gate wraps under `packages/motion-engine/src/node/gate.ts`; widen the allowlist there, not here.

For motion-graphics renders, Claude authors ONE Remotion TSX file per video (not per scene) via `services/visuals/tsx/tsx.go`; the sidecar at `apps/worker-render/src/sidecar/renderClaudeTSX.mjs` bundles it with `@remotion/bundler` and renders via `@remotion/renderer`. Prompt steering, not code changes, is where almost all style/quality iteration happens — but a few structural traps need code or infra fixes that are not obvious from the prompt output.

## The LLM has NO access to the Remotion skills — bake canonical patterns into the system prompt

The `format/remotion-tsx` system prompt (seeded in `services/db/migrations/0003X_tsx_system_prompt_*.sql` and loaded at request time by the TSX adapter) is Claude's ONLY source of Remotion knowledge. It is a bare Anthropic API call from Go — no MCP, no skill-loader, no file access. If the Remotion team's `remotion-markup` / `remotion-captions` / `remotion-transitions` skills say "use `Easing.bezier()` and inline `interpolate` in `style`" and "use `createTikTokStyleCaptions()` from `@remotion/captions`", that only reaches Claude if the prompt body says so verbatim. A system prompt that just says "write a Remotion scene" gets a plausible-looking file that quietly violates every best-practice rule.

Before every meaningful prompt rewrite, re-load the Remotion skill files locally and transcribe the authoritative rules into the system prompt body:

```
skill_view(name='remotion-markup')                             # general rules + file index
skill_view(name='remotion-markup', file_path='timing.md')       # Easing + interpolate + perceptual-scale
skill_view(name='remotion-markup', file_path='transitions.md')  # TransitionSeries composition
skill_view(name='remotion-markup', file_path='multi-scene-video.md')
skill_view(name='remotion-captions', file_path='display-captions.md')  # Caption type + TikTokPage pattern
```

Then embed the actual rules in the prompt as both prose AND a working worked example that uses the pattern end-to-end. The worked example is the strongest signal — Claude mimics it more reliably than it follows prose rules.

Always-on canonical rules the prompt MUST state verbatim (not paraphrased):

- **Keep `interpolate()` INLINE inside `style`.** Do NOT compute into a const and read later. Studio editability depends on inline literals.
- **Use individual `scale`, `translate`, `rotate` CSS properties, NOT the `transform: '...'` string.** The string form is uneditable in Studio and breaks CSS transform-value interpolation across keyframes.
- **For every scale animation pass `output: 'perceptual-scale'`.** Linear scale compresses visually as the value grows.
- **Use `Easing.bezier(0.16, 1, 0.3, 1)` or `Easing.spring({damping: 200})`.** Linear is almost always wrong for anything the viewer notices.
- **Always clamp with `extrapolateLeft: 'clamp', extrapolateRight: 'clamp'`** unless intentional overshoot.
- **Multi-scene composition uses `<TransitionSeries>` from `@remotion/transitions`,** not back-to-back `<Sequence>`. Transitions overlap scenes and shorten total duration; keep them short (6-10 frames) for snappy brainrot-style cuts.
- **Captions use the official `Caption` type from `@remotion/captions` + `createTikTokStyleCaptions()` for pagination,** not a hand-rolled caption pill. The adapter must EMIT captions in the official shape (see next section).

Anti-patterns the prompt must explicitly reject (so Claude's self-check filters them out):

- CSS `transition:`, CSS `animation:`, Tailwind animation classes — do not render in a video.
- Hand-rolled caption pagination instead of `createTikTokStyleCaptions`.
- Back-to-back `<Sequence>` instead of `<TransitionSeries>` for multi-scene videos.
- `transform:` strings instead of individual CSS properties.
- Omitting `output: 'perceptual-scale'` on scale animations.

## The adapter must emit captions in the EXACT `@remotion/captions` JSON shape

From `services/visuals/tsx/prompt.go`, the per-scene brief block must serialise Whisper timings as the official `Caption` struct with ABSOLUTE timings from the start of the video (not scene-local). This matches the JSON the system prompt tells Claude to pass straight into `createTikTokStyleCaptions()`:

```go
type remotionCaption struct {
    Text        string `json:"text"`
    StartMs     int64  `json:"startMs"`
    EndMs       int64  `json:"endMs"`
    TimestampMs *int64 `json:"timestampMs"`
    Confidence  *int64 `json:"confidence"`
}
// text includes a leading space on every token after the first — `whiteSpace: 'pre'`
// in the Claude-authored CaptionPage relies on this.
// startMs/endMs are the per-word Whisper offsets + the running scene startMs,
// NOT scene-local offsets. The TikTokPage.tokens.{fromMs, toMs} values the renderer
// compares against `useCurrentFrame()` are absolute from video start.
```

Sending scene-local offsets, or omitting the leading-space convention, causes Claude's caption highlight to desynchronise or render as `wordwordword` with no gaps. There is no in-process test that catches this — only the rendered MP4 does, so verify with a visual pass after any `prompt.go` edit.

## The sidecar needs an explicit webpack `resolve.modules` override to find `@remotion/*` subpackages

`apps/worker-render/src/sidecar/renderClaudeTSX.mjs` writes the Claude TSX + a synthesised entrypoint into a scratch temp dir (`/tmp/openstudio-renders/<rid>/`) that has NO `node_modules` of its own. By default `@remotion/bundler`'s webpack walks UP from the entrypoint and finds nothing — any `import ... from '@remotion/captions'` or `'@remotion/transitions'` in Claude-authored TSX fails to bundle:

```
ERR_MODULE_NOT_FOUND: '@remotion/captions'
  resolve as module
    /tmp/openstudio-renders/<rid>/node_modules doesn't exist
    /tmp/openstudio-renders/node_modules doesn't exist
    /tmp/node_modules doesn't exist
    ...
```

Fix (apply ONCE, lives in the sidecar — not a per-render concern):

```js
const workerRenderRoot = path.resolve(__dirname, '..', '..');
const nodeModulesDir = path.join(workerRenderRoot, 'node_modules');
const serveUrl = await bundle({
  entryPoint: entryTsx,
  webpackOverride: (cfg) => ({
    ...cfg,
    resolve: {
      ...(cfg.resolve ?? {}),
      modules: [nodeModulesDir, ...((cfg.resolve && cfg.resolve.modules) || ['node_modules'])],
    },
  }),
});
```

Any Remotion subpackage Claude is allowed to import must be an actual dependency of `apps/worker-render` — add via `pnpm --filter @openstudio/worker-render add @remotion/<pkg>@^<same-major-as-bundler>`. The AST allowlist at `services/visuals/tsx/astcheck/sidecar/tsx-check.mjs` already permits any `@remotion/*` specifier, so widening the prompt to allow a new subpackage is a one-side change — the gatekeeper is whether worker-render's `node_modules` has it.

## Director produces the brief shape; prompt steering happens in TWO places

Storytelling style and per-scene STRUCTURE are driven by `apps/api/content_storyboard.go` (DIRECTOR prompt — `switch sc.Kind` cases for `motion-graphics` vs `ai-clip-reel`); FRAME-level rendering style is driven by the TSX system prompt (migrations under `services/db/migrations/0003X_tsx_system_prompt_*.sql`) PLUS the per-request user prompt builder in `services/visuals/tsx/prompt.go`.

Which knob to turn for which problem:

- Wrong scene MIX (every scene is the same mechanism, or hooks/payoffs missing, or no illustration variety) → DIRECTOR prompt in `content_storyboard.go`. The brief shape the DIRECTOR emits lands in the TSX adapter as `visual.prompt`; iterate on it by rendering one script WITHOUT rendering video (hit `/api/v1/live/scripts` and inspect `storyboard.scenes[].visual.prompt`).
- Wrong per-frame AESTHETIC (character missing, caption pill not word-timed, headlines centered when they should be left-aligned, decorative hero scenes instead of templated panels) → `format/remotion-tsx` system prompt. Rewrite via a fresh `0003X_tsx_system_prompt_*.sql` migration that `UPDATE`s the body in place (slot='format', selector='remotion-tsx') — do NOT re-INSERT, the row is seeded once by migration 00030 and updated in place thereafter.
- Caption shape / timing emission → `prompt.go` (the per-request user prompt builder). This is Go code, so an in-process test pins it (see `TestGenerate_WordTimingsInPrompt` in `services/visuals/tsx/tsx_test.go` — asserts the exact `"startMs":...,"endMs":...` JSON substring and the `@remotion/captions` label are both present).

After editing EITHER the DIRECTOR prompt OR the TSX system prompt, verify the real rendered MP4 — never trust the TSX source alone (it can look right and render wrong, or vice versa). Pull the TSX via `GET /api/v1/renders/<rid>` → `inputProps.tsx`, grep for the canonical-pattern markers (`createTikTokStyleCaptions`, `Easing.bezier`, `perceptual-scale`, `TransitionSeries`), AND open the MP4 in a player.

## Prompt-rewrite cadence: migration per iteration, not one giant rewrite

The TSX system prompt body is ~12-25 KB of carefully-balanced instructions. Treat each prompt revision as its own migration (`00032_...`, `00033_...`, `00034_...`), with the `-- +goose Down` restoring the previous body verbatim. This gives a clean git history of prompt evolution and makes it trivial to A/B compare a render against the previous prompt by `goose down` → re-run.

DO NOT edit a prior prompt migration in place. Prior migrations have run against the local DB; re-running them is a no-op (goose tracks version). The new body MUST ship as a new migration file.

Sizing: the Anthropic HTTP client timeout at `services/ai-gateway/anthropictext/anthropictext.go` must be 10 minutes, not 60 seconds — a complex 60-70s video with 7-8 scenes takes Claude 100-150s to generate 15-25K tokens of TSX. The 60s default silently retries 3× and burns token budget on identical rejections.

## Visual verification playbook

1. Pull the TSX source: `curl -s http://localhost:4000/api/v1/renders/<rid> -H 'Authorization: Bearer $KEY' | jq -r '.inputProps.tsx' > /tmp/scene.tsx`
2. Grep for canonical-pattern markers (the ones the system prompt required). Absence of any marker is a prompt-fidelity miss, worth tightening the prompt wording OR adding a one-shot rejection rule to the AST allowlist if the miss is a hard quality issue.
3. `mc cp local/openstudio-private/workspaces/<ws>/renders/<rid>.mp4 ~/Desktop/<name>.mp4 && open ~/Desktop/<name>.mp4`.
4. For a reference-comparison iteration, extract keyframes from BOTH the reference MP4 and the rendered MP4 at matched offsets (`ffmpeg -ss <t> -frames:v 1 ...`), tile them with `ffmpeg -i '%02d.jpg' -vf tile=3x5`, and send both tiles to `vision_analyze` with a targeted "describe the aesthetic" question. Describing both frame grids in words forces the ACTUAL differences into view instead of imagined ones.
