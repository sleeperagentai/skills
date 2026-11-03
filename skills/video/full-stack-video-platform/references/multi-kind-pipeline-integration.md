# Multi-kind video pipeline: orchestrator integration + end-to-end verification

Applies whenever an API triggers a workflow engine (Temporal, Prefect, Celery, RQ) that runs the real render, while the API itself still owns the client-facing status surface. Also applies to any registry-driven platform that dispatches one of N `kinds` (compositions, templates, product types) through a shared pipeline.

## 1. Never race a local "simulator" against the real workflow

A common shape: the API keeps a legacy in-process progress driver so `GET /renders/{id}` still animates through stages, AND fires a Temporal/Prefect workflow that produces the real MP4. If both run, the local simulator finishes first (it just sleeps and stubs a URL) and stamps a placeholder `outputUrl` onto the record. The workflow's real output is uploaded but never surfaced — clients download the placeholder and never notice.

**Rule: when a workflow engine is wired, the API path must AWAIT its result and only then persist status/output.** The simulator is a *fallback* for when dial-out fails, not a parallel track.

Concrete Go pattern for a Temporal-backed API:

```go
// bad: fire workflow AND run simulator; simulator wins the race
if s.temporal != nil {
    s.temporal.StartRender(ctx, in)
    go s.simulateRender(rec)   // <- races and clobbers the real result
}

// good: fire workflow, then wait for its result in a goroutine
if s.temporal != nil {
    wfID, runID, err := s.temporal.StartRender(ctx, in)
    if err != nil {
        go s.simulateRender(rec)  // real fallback
        return
    }
    go s.awaitTemporalResult(rec, wfID, runID)
} else {
    go s.simulateRender(rec)
}
```

Inside `awaitTemporalResult`:
1. Start a *bounded* stage-ticker goroutine that advances `rec.Stage` for UX only, gated on `rec.Status != "done"`.
2. `client.GetWorkflow(ctx, wfID, runID).Get(ctx, &out)` with a generous timeout (15m for renders).
3. On success: set `rec.OutputURL = MEDIA_PUBLIC_URL + "/" + out.OutputKey` — the S3 key from the workflow, never a synthesised path. Persist to DB. Emit `render.completed` webhook.
4. On error: mark failed, persist, emit `render.failed`.

The stage-ticker is decorative; the source of truth is `out.OutputKey` from the workflow.

## 2. The kind registry lives in FOUR places and drifts silently

A kind (`ai-slideshow`, `text-to-image`, `news-recap`, ...) is only complete when it exists in every one of these:

1. **API kind registry** — the `kindByRoute` / `kindByID` / `kindEnabled` maps that gate `POST /api/v1/{route}/projects`. Missing here → `UNSUPPORTED_VIDEO_TYPE` on project creation.
2. **Pricing table** — `baseByKind` (or equivalent). Missing here → `unknown kind` error on the render call, AFTER project creation succeeded. The failure moves one hop downstream and looks like a bug in the render dispatcher.
3. **Node worker's `buildInputProps(input)`** (or equivalent kind→composition mapping) — converts `input.Kind` into the composition ID and its shaped input JSON. Missing here → falls through to the default (usually VoiceOver), silently rendering the wrong composition.
4. **Remotion `Root.tsx`** — the `<Composition id="..." component=... calculateMetadata=... />` registration. Missing here → `selectComposition` throws at bundle-load; workflow fails.

**Rule: adding a kind is a four-file changelist. Grep for every place the previous kind's ID appears (`grep -rn 'ai-voice-over-video'`) and mirror all four hits.**

## 3. Verify multi-kind pipelines with md5 diffing, not just "it rendered"

When a pipeline has N kinds all sharing a fallback path (Go inline renderer, ffmpeg placeholder, whatever), a bug that routes every kind to the fallback produces N *superficially valid* MP4s — same dimensions, same codec, same duration, plausible sizes. `ls` looks fine. `ffprobe` looks fine. Only the payload is wrong.

**Rule: after running one render per kind, `md5sum /tmp/renders/*.mp4` — if any two kinds share a hash they share a code path, and the mapping is broken.** Bytes should differ per composition unless two routes intentionally share (e.g. `brainrot` and `character-dialogue` both mapping to the CharacterDialogue composition — those SHOULD match).

Second-layer verification, cheap and worth it every time:
- `ffprobe -v error -show_entries stream=nb_frames -select_streams v:0 -of csv=p=0 file.mp4` — frame count should reflect the composition's declared duration × fps, not the workflow-engine's default.
- Tail the worker's log and confirm the composition ID that got selected matches the kind you requested (`"id":"Slideshow"` not `"id":"VoiceOver"`).

## 4. Webhook receiver + signature check as a first-class E2E fixture

Even a 30-line receiver is enough to prove sign+deliver end-to-end:

```python
# /tmp/wh-receiver.py
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        body = self.rfile.read(n)
        rec = {
            'sig': self.headers.get('X-Signature'),
            'event': self.headers.get('X-Event'),
            'body': body.decode(),
        }
        with open('/tmp/wh.jsonl','a') as f: f.write(json.dumps(rec)+'\n')
        self.send_response(200); self.end_headers()
    def log_message(self, *a, **k): pass
http.server.HTTPServer(('127.0.0.1', 5580), H).serve_forever()
```

Run it in the background, register a subscription with `curl POST /webhooks`, run a render, then `wc -l /tmp/wh.jsonl` and inspect one record. Confirms: (a) the API emits on the completion path, (b) the signature header is present, (c) the payload has the fields you promised (renderId, outputUrl, durationMs). A single test render exercises the entire path.

**Rule: a passing render alone does not confirm webhook delivery. If webhooks are part of the spec, boot the receiver before the render, not after — otherwise you're inferring delivery from logs.**

## 5. In-memory API state resets on restart — mint a new key after every rebuild

When the API keeps API keys in an in-memory `keys` map (in addition to the DB), a rebuild-and-restart during development invalidates every key the previous instance issued, even though the DB row still exists. The rebuilt instance boots, seeds a demo key, and rejects the old bearer token as `INVALID_API_KEY` — which reads as an auth bug instead of a state-reset consequence.

**Rule: after every API rebuild, mint a fresh key via `POST /internal/keys` before running follow-up tests.** Keep the key in a file (`/tmp/apikey.txt`) so the same shell script works across restarts:

```bash
curl -sf -X POST $API/internal/keys -H 'content-type: application/json' \
  -d '{"name":"e2e"}' > /tmp/rawkey.json
python3 -c "import json; open('/tmp/apikey.txt','w').write(json.load(open('/tmp/rawkey.json'))['key'])"
```

(Tool output that includes an API key may be redacted mid-string by the sandbox. The full key is still on disk — read it back from the file, don't paste from terminal output.)

## 6. Config secrets that block boot are load-bearing in dev too

Production-only guards (`AUTH_SESSION_SECRET must be >=32 bytes`, `WEBHOOK_HMAC_SECRET must be >=32 bytes`) will *print a warning and continue* in some codebases, but *refuse to start* in others. When a Go binary logs `configuration error; invalid: ...` and exits, an already-listening process from the previous rebuild is what answers `/healthz` — you're testing the old build against the new source. `lsof -i :<port>` before rebuilding confirms whether the old PID is still bound.

**Rule: before assuming a new build is running, `lsof -i :<port>` and match the PID against the one you just started. `/healthz` cannot distinguish stale binaries.**

Export dev-only secrets once per session env file:

```bash
export AUTH_SESSION_SECRET="dev-only-session-secret-01234567890123"
export API_KEY_HMAC_SECRET="dev-only-hmac-secret-01234567890123456"
export WEBHOOK_HMAC_SECRET="dev-only-webhook-secret-01234567890123"
```

## 7. Long shell loops die inside the tool timeout; drive one iteration per call

An E2E script that iterates over N kinds with per-item polling (`sleep 3` × 40 iterations × 6 kinds) will hit any 7-minute tool timeout mid-loop, kill the shell, and leave later iterations as zero-byte files. Debugging that looks like "why did the workflow silently fail for kind 3?" when in fact the *shell* was reaped, not the workflow.

**Rule: write a `one-render.sh <route> <title>` helper that runs exactly one iteration and returns, then invoke it once per kind from the driver.** Each invocation is bounded, so a mid-run timeout only loses that kind, not all remaining kinds. Renders already in flight in Temporal will still complete server-side and can be inspected afterwards from the API.
