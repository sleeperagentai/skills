# Remotion + edge-tts End-to-End Render Recipe

Verified working pipeline for producing a 9:16 short with character voiceover, motion graphics, and captions — using only free tools (no paid API keys required). Serves as a reference implementation until the Prefect stubs in `backend/prefect/flows/video_processing.py` are wired to real backends.

## Directory layout

```
brainrotshorts/
├── public/
│   └── <slug>/
│       ├── vo.mp3          # generated voiceover (staticFile-loadable)
│       └── script.json     # {lines: [{t: seconds, text: string}]}
├── src/
│   ├── Root.tsx            # MUST be Remotion root (only <Composition/>)
│   └── <SceneName>/
│       └── <SceneName>.tsx # exports the component
└── remotion.config.ts
```

## Step 1 — Script (as JSON with timing marks)

```json
{
  "topic": "The Cloud",
  "character": "Homer Simpson",
  "duration_target_sec": 30,
  "lines": [
    { "t": 0.0,  "text": "Mmm... the cloud." },
    { "t": 2.2,  "text": "For years, I thought..." }
  ]
}
```

**Pitfall**: hand-authored `t` values drift when TTS regenerates. Long-term fix — replace with Whisper word-timestamps. Short-term — set `t` slightly *after* where each line starts in the VO to avoid caption leading the audio.

## Step 2 — Voiceover (free "Homer-ish" male voice)

```bash
# 1. Base TTS
edge-tts --voice en-US-GuyNeural --rate=-10% --pitch=-8Hz \
  --text "$(cat script.txt)" --write-media vo_raw.mp3

# 2. Pitch-down + speed-up to compensate (preserves intelligibility)
ffmpeg -y -i vo_raw.mp3 \
  -af "asetrate=24000*0.86,aresample=48000,atempo=1.24,volume=1.4" \
  vo.mp3

# 3. Check duration matches target (~30s)
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 vo.mp3
```

Tuning: `asetrate` multiplier `0.85–0.90` = pitch drop; `atempo` `1.15–1.30` restores tempo. Going below 0.82 gets muddy. `edge-tts --list-voices | grep -iE "en-US.*Male"` for alternatives (`AndrewNeural`, `BrianNeural`, `ChristopherNeural`, `EricNeural`, `RogerNeural`, `SteffanNeural`).

## Step 3 — Remotion Root.tsx (critical)

```tsx
import "./index.css";
import React from "react";
import { Composition } from "remotion";
import { HomerCloud } from "./HomerCloud/HomerCloud";

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="HomerCloud"
      component={HomerCloud}
      durationInFrames={30 * 31}  // 31s @ 30fps
      fps={30}
      width={1080}
      height={1920}
    />
  </>
);
```

**Pitfall (real, happened this session)**: The `brainrotshorts` project shipped with `<BrowserRouter>` and `<Routes>` in `Root.tsx` — that's a Next.js web-app shell, not a Remotion root. `npx remotion render` will fail with confusing errors. If the platform serves both a web UI and Remotion compositions, they need separate entry points.

## Step 4 — Composition patterns

### Audio + timing

```tsx
import { Audio, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
<Audio src={staticFile("homer/vo.mp3")} />
const frame = useCurrentFrame();
const { fps } = useVideoConfig();
const t = frame / fps;  // seconds
```

### Active-line lookup (matches script.json timing)

```tsx
const activeIndex = LINES.reduce(
  (idx, line, i) => (t >= line.t ? i : idx), 0
);
const activeLine = LINES[activeIndex];
```

### Mouth-flap envelope (avoids talking after line ends)

```tsx
const nextT = LINES[activeIndex + 1]?.t ?? durationInFrames / fps;
const lineProgress = (t - activeLine.t) / Math.max(0.2, nextT - activeLine.t);
const envelope = lineProgress < 0.9 ? 1 : Math.max(0, 1 - (lineProgress - 0.9) * 10);
const mouth = envelope * (0.5 + 0.5 * Math.sin(t * 14));
```

### Caption with per-word emphasis (spaces intact)

```tsx
const words = text.split(/\s+/).filter(Boolean);
// ...
{words.map((w, i) => (
  <React.Fragment key={i}>
    <span style={{ color: isEmph(w) ? YELLOW : "white" }}>{w}</span>
    {i < words.length - 1 ? " " : ""}
  </React.Fragment>
))}
```

**Pitfall**: `text.split(/(\s+)/)` keeps spaces as their own tokens; if you then filter them out or wrap each in `<span display:inline-block>`, words run together (`ForyearsIthought`). The Fragment-with-explicit-space pattern above avoids it.

## Step 5 — Render

```bash
npx remotion render HomerCloud out.mp4 \
  --codec=h264 \
  --pixel-format=yuv420p \
  --crf=18 \
  --concurrency=4 \
  --log=info
```

- `--pixel-format=yuv420p` is REQUIRED for Telegram, QuickTime, iOS players. Without it, some players show a black screen.
- `--crf=18` = visually-lossless quality (larger file). Use `--crf=23` for social-media-acceptable at smaller size.
- 30s @ 30fps 1080x1920 renders in ~30-45s wall time on an M-series Mac with concurrency=4.

## Step 6 — QA gate (before delivery)

```bash
for t in 2 8 15 20 28; do
  ffmpeg -y -ss $t -i out.mp4 -frames:v 1 preview_t${t}.jpg
done
```

Then feed each frame to a vision model with a rubric:
- Is the caption readable (proper spacing, no clipping, no color contrast issue)?
- Is the speaker/character un-occluded by props?
- Is there dead space or awkward composition?
- Are branded elements (title cards, watermark) placed correctly?

Auto-flag issues → re-render the offending scene only (using `--frames=start-end`) rather than the whole video.

## Step 7 — Delivery

```
MEDIA:/absolute/path/to/out.mp4
```

Telegram delivers MP4 as native inline video. Keep under 50 MB for auto-preview; over that it becomes a document.

## Common failure modes seen this session

| Symptom | Cause | Fix |
|---|---|---|
| `remotion render` errors about missing composition | `Root.tsx` renders a `<BrowserRouter>` app, no `<Composition>` | Rewrite Root.tsx to only register compositions |
| Captions read `Foryears,Ithoughtthecloud` | Split-then-filter ate spaces | Use `.split(/\s+/).filter(Boolean)` + explicit space between spans |
| Homer's shirt looks like a detached rectangle floating below the head | SVG body drawn as small rect not extending to viewBox bottom | Draw body path from shoulders `M120,560 ... L520,720 L100,720 Z` (runs off SVG bottom) |
| Props overlap character body | Hardcoded scene bottom-offsets chosen by eye | Move to data-driven scene layout; QA-gate before ship |
| Voice sounds robotic, not the target character | edge-tts + pitch shift ceiling | Add ElevenLabs / XTTS-v2 backend behind `NarrationProvider` abstraction |

## What's still missing from the platform (Prefect stub → real work)

The `backend/prefect/flows/video_processing.py` tasks (`generate_script`, `generate_narration`, `generate_captions`, `assemble_video`) all `time.sleep()` and return fake `s3_key` strings. To make them real:

1. `generate_script` → call LLM with strict JSON schema for beat sheet.
2. `generate_narration` → call `NarrationProvider` (edge/elevenlabs/xtts), upload to MinIO, return real `s3_key`.
3. `generate_captions` → download VO from S3, run Whisper word-timestamps, upload JSON.
4. `assemble_video` → shell out to `npx remotion render` (or `@remotion/renderer` Node bindings), upload MP4, update `Video.video_s3_key + status=PROCESSED` in Postgres.
