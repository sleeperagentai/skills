# Async-write + realtime events architecture

Applies to any video/media platform where a browser dashboard kicks off long-running generation (render, TTS, ASR, script draft, moderation) and needs live progress. Verified end-to-end against a Go + chi + Temporal API with a Next 15 dashboard.

## The contract

**Every POST that starts work returns 202 within <200ms with `{jobId, ...}` and delegates to a goroutine.** No handler ever calls `client.GetWorkflow().Get()` inline, no handler blocks on an LLM call, no handler waits for a render. Fast-fail credit / auth / validation errors still return synchronously (they finish in <10ms). The dashboard learns about progress through two channels only: a single SSE stream, and a per-resource polling GET as a safety net when no event has landed in >5s.

## Server side

1. **In-memory pub/sub bus, per-workspace fan-out, bounded buffers, drop-oldest on overflow.** `Publish` NEVER blocks a producer — a slow client must not stall a render worker. Buffer size 32-64 per subscriber; on full buffer, drain the oldest event and enqueue the new one. Every write handler calls `bus.Publish(workspaceID, {type, at, data})` immediately after the DB write and BEFORE returning 202.

2. **Event types are dotted-namespace strings:** `render.queued`, `render.progress` (data: `{renderId, stage, progress}`), `render.completed` (data: `{renderId, outputUrl, durationMs}`), `render.failed`, `render.cancelled`, `series.episode.queued`, `script.completed`, `captions.completed`, `project.updated`, `credits.updated`. Stable strings so the client can pattern-match.

3. **The SSE endpoint MUST bypass request-timeout middleware.** A router-level `middleware.Timeout(30s)` (chi's, or any equivalent) kills the SSE handler at the 30s mark and the client sees the stream close mid-render. Move Timeout INSIDE a route group that excludes `/events/stream`, or register the SSE route on a subrouter that has no timeout. Set `X-Accel-Buffering: no` to disable nginx buffering, `Cache-Control: no-cache, no-transform`, `Connection: keep-alive`, and emit a `: keepalive <ts>\n\n` comment every 15s so intermediaries don't kill idle connections.

4. **Send an initial `event: ready` frame immediately after subscribe.** This lets the client flip a "live" connection dot before any real events arrive; it also flushes the response headers so proxies commit to streaming.

5. **Dual-publish through webhooks.** If the platform emits outbound webhooks on `render.completed`/`render.failed`, have the webhook emitter ALSO publish to the in-memory bus — the dashboard shouldn't need an external webhook subscriber to see its own events. Publishes to no subscribers drop silently.

6. **Auth on the SSE stream is the same session-cookie or Bearer that guards the rest of the API.** The middleware resolves a Principal (userId, workspaceId, scopes) and the SSE handler subscribes ONLY to that workspaceId. No cross-tenant leakage possible.

## Client side

1. **One EventSource for the whole dashboard, mounted in the root layout.** Not one per page — open a single `EventSource('/api/v1/events/stream', {withCredentials:true})` in a React context provider, expose `useRenderEvents(renderId?)`, invalidate SWR/React-Query caches on relevant frames. Exponential-backoff reconnect capped at 30s. Close on sign-out.

2. **After a POST-to-render, navigate immediately to the render-detail route** — no blocking spinner on the studio page. The render-detail component subscribes via `useRenderEvents(id)`, animates its progress bar off `render.progress`, swaps in `<video>` when `render.completed` arrives.

3. **Polling is only a safety net.** GET `/renders/{id}` every 3s ONLY when no event has arrived in >5s AND status is non-terminal. When events flow, polling is off.

4. **Toast on terminal events** (`render.completed` / `render.failed`) via sonner or equivalent; never toast on optimistic client state.

## Verification protocol

With the API running and a session cookie in `cookies.txt`:

1. Open the stream: `curl -sN -b cookies.txt -H 'Accept: text/event-stream' /api/v1/events/stream`.
   First frame within 1s: `event: ready\ndata: {...}`.
2. In another shell, POST a render: `time curl -X POST /voiceover/projects/{id}/render`.
   Expect **HTTP 202 in <200ms**.
3. Watch the SSE shell fill with `event: render.progress` frames at the stage cadence, then one `event: render.completed` with `outputUrl` — all under 10s for a fake renderer, seconds-to-minutes for real.
4. If frames don't arrive but `render.progress` appears in the server log, the SSE subscriber and the publisher hold DIFFERENT bus references (stale server restart, or two `bus.New()` calls). Confirm by logging `SubscriberCount(workspaceID)` at publish time — `subs: 0` after a successful `SSE subscribed` for the same workspace means either the api restarted after the curl connected (curl is still open to a dead process; reconnect) or a second bus exists somewhere.

## Pitfalls

- **A ping-pong dev restart leaves stale SSE curls open** to the dead server; a new server has zero subscribers and events publish into the void. Restart the SSE client after every api restart; kill lingering curls (`pkill -f 'curl.*events/stream'`) before diagnosing "events not arriving."
- **The `render.progress` publisher lives on whichever code path actually runs the render**: real Temporal workflow (via a stage-advance goroutine in `awaitTemporalResult`), a local simulator, OR a `realRender` ffmpeg driver. If you add publishRenderProgress to only one path and the deployment falls back to another, events silently stop. Add the publish in the `onStage` callback that ALL renderers accept, not next to `Temporal wired` logs.
- **NEVER return a full render result from a write endpoint.** If a caller wants the finished MP4 URL, they subscribe to SSE or poll GET /renders/{id}. Blocking a POST for the whole render will time out proxies, break StrictMode double-fires, and burn API keys on retries.
- **Cross-origin SSE and cookies don't mix reliably in the browser.** Even with `EventSource(..., {withCredentials:true})` and correct CORS, some browsers still fail on Set-Cookie during the initial connect. Proxy SSE same-origin via a Next rewrite (see the nextjs-app-router-production skill's rule #8) and stop debugging CORS.
