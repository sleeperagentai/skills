---
name: async-jobs-and-sse-go
description: Go async 202 job APIs + SSE progress streams.
---

# Async job APIs + SSE progress streams in Go

A long-running mutation (video render, audio synthesis, LLM generation, batch transcode) MUST NOT hold the HTTP connection. The client fires-and-forgets, the server acknowledges with a job/render id, and progress reaches the client through a separate long-lived stream. This skill is the shape that works.

## Always-on rules

- **Every write that triggers work returns 202 Accepted in <200ms with `{jobId, resourceId, status:"queued"}`.** No handler calls `client.GetWorkflow().Get()` or `workflow.Result()` or `<-doneChan` inline. Background work runs in a `go` from inside the handler, after all fast validation (auth, quota, credit reserve) has already 200/402'd if needed.
- **Fast-fail comes before async.** Credit checks, quota lookups, idempotency-key conflicts, principal auth — all run synchronously and return their error code (402 INSUFFICIENT_CREDITS, 409 IDEMPOTENCY_CONFLICT, etc.) in a millisecond or two. Only after those pass do you enqueue.
- **Progress reaches clients via a single per-workspace (or per-tenant) SSE stream**, not one stream per resource. Clients subscribe once and filter by `event: <type>` + `data.resourceId`. Per-resource streams do not scale and duplicate keepalive traffic.
- **In-memory event bus is per-tenant, non-blocking, drop-oldest on overflow.** A slow SSE client must never back-pressure a render worker. Publish uses `select { case ch <- ev: default: /* drop oldest, retry once */ }`.
- **Never wrap SSE routes in a request timeout middleware.** `chi.middleware.Timeout(30 * time.Second)` at the ROOT router silently closes SSE connections after 30s. Apply Timeout to a subgroup that excludes the events endpoint, or register the SSE route on its own subrouter.
- **SSE framing that actually works through proxies:** `Content-Type: text/event-stream`, `Cache-Control: no-cache, no-transform`, `Connection: keep-alive`, `X-Accel-Buffering: no` (disables nginx buffering), plus a 15s SSE comment line (`: keepalive <unix>\n\n`) to keep intermediaries from killing idle connections. Call `http.Flusher.Flush()` after every frame.
- **Publish must happen from EVERY code path that advances state.** If you have a `simulateRender` fallback and a `realRender` (or a Temporal-await goroutine), each of them independently calls `bus.Publish` — a single-site publish that only fires in one branch is the most common "my events don't arrive" bug.
- **Session-cookie auth for SSE:** the browser's `EventSource` sends cookies only when constructed with `withCredentials: true` AND the server responds with `Access-Control-Allow-Credentials: true` and a specific (not `*`) origin.

## Procedure

### 1. Event bus (per-tenant)

Build once, share via `state`. Per-subscriber buffer 32–64. On overflow: drain one, enqueue new. Cancel func removes the sub and closes the channel exactly once (guard with a `done` sentinel to survive double-cancel).

```go
type Event struct {
    Type        string         `json:"type"`
    WorkspaceID string         `json:"workspaceId"`
    At          time.Time      `json:"at"`
    Data        map[string]any `json:"data"`
}

func (b *Bus) Publish(ws string, ev Event) { /* non-blocking, drop-oldest */ }
func (b *Bus) Subscribe(ws string) (<-chan Event, func()) { /* cancel returned */ }
```

### 2. Write handlers (202 pattern)

```go
func (s *state) handleRender(w http.ResponseWriter, r *http.Request) {
    p := principalFrom(r.Context())
    if _, err := s.ledger.Reserve(ctx, p.WorkspaceID, quote.Total, "render"); err != nil {
        writeErr(w, errs.From(err)); return // 402 in a millisecond
    }
    rec := &renderRec{ID: newID(), WorkspaceID: p.WorkspaceID}
    s.renders[rec.ID] = rec
    go s.runRender(rec)
    s.events.Publish(p.WorkspaceID, events.Event{Type: "render.queued", Data: ...})
    writeJSON(w, 202, map[string]any{"id": rec.ID, "status": "queued", "progress": 0})
}
```

### 3. Progress publisher inside worker goroutine

Call `bus.Publish` after every state advance, and separately from the outbound webhook emitter. Wire the webhook emitter to publish to the bus too, so `render.completed` / `render.failed` show up on SSE even when webhooks are disabled.

### 4. SSE endpoint

```go
func (s *state) handleEventsStream(w http.ResponseWriter, r *http.Request) {
    flusher, _ := w.(http.Flusher)
    w.Header().Set("Content-Type", "text/event-stream")
    w.Header().Set("Cache-Control", "no-cache, no-transform")
    w.Header().Set("Connection", "keep-alive")
    w.Header().Set("X-Accel-Buffering", "no")
    w.WriteHeader(http.StatusOK)

    ch, cancel := s.events.Subscribe(p.WorkspaceID); defer cancel()
    writeSSE(w, "ready", map[string]any{"workspaceId": p.WorkspaceID}); flusher.Flush()

    keepalive := time.NewTicker(15 * time.Second); defer keepalive.Stop()
    for {
        select {
        case <-r.Context().Done(): return
        case ev, ok := <-ch:
            if !ok { return }
            writeSSE(w, ev.Type, ev); flusher.Flush()
        case <-keepalive.C:
            fmt.Fprintf(w, ": keepalive %d\n\n", time.Now().Unix()); flusher.Flush()
        }
    }
}

func writeSSE(w io.Writer, name string, payload any) {
    buf, _ := json.Marshal(payload)
    fmt.Fprintf(w, "event: %s\ndata: %s\n\n", name, buf)
}
```

### 5. Router wiring (chi)

```go
r := chi.NewRouter()
r.Use(middleware.RequestID, middleware.RealIP, middleware.Recoverer, corsMiddleware)
// NOTE: no r.Use(middleware.Timeout(...)) at the root.

r.Route("/api/v1", func(r chi.Router) {
    r.Use(authMiddleware)
    // SSE FIRST — registered before the timeout group so it never picks it up.
    r.Get("/events/stream", st.handleEventsStream)
    r.Group(func(r chi.Router) {
        r.Use(middleware.Timeout(30 * time.Second))
        r.Get("/me", st.handleMe)
        // ... everything else
    })
})
```

### 6. Verify live

```bash
# Async 202 (want HTTP=202 TIME<0.05)
curl -w '[HTTP=%{http_code} TIME=%{time_total}s]\n' -X POST -H 'Idempotency-Key: '$(uuidgen) .../render

# Fast-fail (want HTTP=402 TIME<0.01)
curl -w '[HTTP=%{http_code} TIME=%{time_total}s]\n' -X POST .../render

# SSE ready frame + keepalive
curl -sN --max-time 20 -b cookies.txt -H 'Accept: text/event-stream' .../events/stream
# expect: event: ready\n data: {...}\n\n  then : keepalive <ts>\n\n every 15s

# End-to-end: subscribe first, then fire
(curl -sN -b cookies.txt .../events/stream > sse.log &) ; sleep 1 ; curl -X POST .../render ; sleep 15 ; cat sse.log
```

If the ready frame arrives but progress frames don't, publish is happening on a different `*Bus` instance OR only from one code path. Grep for every worker function (simulator, real renderer, workflow-await, retry) and confirm each calls the progress publisher.

## Pitfalls

- **Root-level `middleware.Timeout` silently kills SSE.** Chi's Timeout wraps the ResponseWriter in a deadline-aware writer; when the deadline hits it swallows further writes and closes the connection with no error. Symptom: SSE clients see the ready frame + one keepalive, then a clean EOF at ~30s.
- **Any middleware that wraps `http.ResponseWriter` MUST explicitly implement `Flush()` (and `Hijack()`) as passthroughs — embedding is not enough.** A status-recorder / tracing / metrics middleware that defines `type recorder struct { http.ResponseWriter; status int }` promotes `WriteHeader` cleanly but Go's `w.(http.Flusher)` type assertion checks the WRAPPER type, finds no `Flush` method, returns `ok=false`, and the SSE handler 500s with `streaming is not supported on this connection`. Symptom: SSE routes return a 500 the instant you add any observability/metrics middleware upstream of them; the ready frame never arrives. Fix: add explicit passthroughs on the wrapper type.

  ```go
  func (r *recorder) Flush() {
      if f, ok := r.ResponseWriter.(http.Flusher); ok { f.Flush() }
  }
  func (r *recorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
      if h, ok := r.ResponseWriter.(http.Hijacker); ok { return h.Hijack() }
      return nil, nil, http.ErrNotSupported
  }
  ```

  Audit every middleware in the chain that wraps `w` — not only the one you just wrote. Writing a test that asserts `w.(http.Flusher) != nil` after the middleware chain is cheap and catches the regression on the next proxy/tracing addition.
- **Every write path must publish.** A refactor that adds `bus.Publish` in the simulator branch but not the real-renderer / Temporal-await branch produces "events don't arrive" bugs that look like bus misconfiguration. Grep every worker function (simulator, real renderer, workflow-await, retry) and confirm each calls the progress publisher.
- **Redacted secrets in captured stdout are not the real value.** Runtimes that redact `sk_live_...`-style keys in terminal output mean you cannot parse a key from a log line to reuse it. Bind local dev to a session cookie instead of round-tripping a printed api key.
- **Renderer completes faster than the client can subscribe.** If a job finishes in <500ms and the SSE listener only opens after the POST returns, no progress frames land. In dev, insert artificial per-stage `time.Sleep(200ms)`; in tests, subscribe BEFORE firing the write.
- **Buffered proxies eat SSE.** Nginx buffers `text/event-stream` unless `X-Accel-Buffering: no`; Cloudflare requires the same header. Without these, clients see 30s of nothing then a flood of frames at once.
- **Do not fan out per-resource SSE streams.** One per-workspace stream + client-side filter on `data.resourceId` is one TCP connection; N per-resource streams is N connections that all keepalive independently and re-auth on every reconnect.
- **EventSource without `withCredentials:true` sends no cookies**, and the server-side CORS response must return a specific `Access-Control-Allow-Origin` (not `*`) plus `Access-Control-Allow-Credentials: true`. Symptom: `/auth/session` works from `fetch`, SSE from `EventSource` gets 401.
- **Cancel-func for Subscribe must be idempotent** — clients disconnect and call it, and a handler `defer cancel()` calls it again. Guard the close of the channel and the delete-from-map with a `sync.Once` or a `done` sentinel channel.
- **Dev environments need seed credits.** If your ledger enforces credit reservation before the goroutine starts, a freshly signed-in dev user with 0 credits gets 402 and never sees the async path. Bootstrap N credits on session-creation in `APP_ENV=development`.

## Client-side (EventSource) contract

- Open ONE EventSource for the whole app, mounted in the root layout.
- Handle `open` → flip a live dot; `error` → exponential-backoff reconnect (cap 30s).
- Dispatch to per-resource subscribers via a React context (`useResourceEvents(id?)`) or an mitt-style emitter. No `new EventSource()` inside individual components.
- Fall back to polling `GET /resource/{id}` only when no event has arrived for >5s AND status is non-terminal. Never poll blindly on top of SSE.
- On sign-out, close the EventSource before redirecting; the browser will otherwise keep reconnecting to an unauth'd endpoint and spam 401s.

## Delegation notes

When this pattern is split across parallel subagents (endpoint author, dashboard author, auth author), STEER each of them mid-flight to enforce the async contract before they finish — an agent that ships synchronous handlers first and "async-ifies later" produces a large uncoordinated rewrite. The steer for the endpoint agent is: *202 in <200ms, no inline `.Get()` on workflows, publish onto the shared bus, never return the full result from a write endpoint*. The steer for the UI agent is: *one EventSource for the app, no per-resource stream, poll only as a >5s fallback, close the stream on sign-out*.
