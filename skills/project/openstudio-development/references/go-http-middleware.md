# Go HTTP middleware traps (apps/api middleware chain)

Standing rules for every middleware installed on the API's chi router
(`r.Use(...)` in `apps/api/main.go`) — including `obs.HTTPMiddleware`,
`sentryx.HTTPMiddleware`, `sessionMiddleware`, `combinedAuthMiddleware`,
and any new one. The chain is deep and runs on EVERY request; a bug in
one wrapper surfaces as a 500 on a feature the author did not touch.

## Any `ResponseWriter` wrapper MUST pass through Flush() and Hijack()

**Rule.** When a middleware wraps `http.ResponseWriter` (to capture
status, buffer the body, record metrics), the wrapper type MUST declare
explicit `Flush()` and `Hijack()` methods that delegate to the inner
writer. Embedding `http.ResponseWriter` as a field does NOT satisfy a
type assertion on the wrapper.

**Mechanism.** Go's `w.(http.Flusher)` type assertion checks the method
set of the WRAPPER type, not the embedded field's. An embedded
`http.ResponseWriter` promotes its methods for direct calls (`w.Flush()`
compiles) but the wrapper type itself does not satisfy `http.Flusher`,
so the assertion returns `ok=false`.

**Symptom.** Every SSE handler behind the chain 500s with
`streaming is not supported on this connection` (or whatever the
handler's fallback message is after the Flusher assertion fails).
First-visible: `/api/v1/live/scripts/stream` — the Script step in the
create wizard dies the moment the user clicks "AI, write for me".
`/events/stream`, `/renders/{id}/events`, and any future SSE handler
fail identically.

**Fix shape** (reference: `services/observability/httpmid.go`):

```go
type statusRecorder struct {
    http.ResponseWriter
    status  int
    written bool
}

// Status capture (what the wrapper exists for).
func (r *statusRecorder) WriteHeader(code int) {
    if !r.written {
        r.status = code
        r.written = true
    }
    r.ResponseWriter.WriteHeader(code)
}

// REQUIRED pass-throughs — guard the inner cast so a non-Flusher inner
// writer no-ops instead of panicking.
func (r *statusRecorder) Flush() {
    if f, ok := r.ResponseWriter.(http.Flusher); ok {
        f.Flush()
    }
}

func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
    if h, ok := r.ResponseWriter.(http.Hijacker); ok {
        return h.Hijack()
    }
    return nil, nil, http.ErrNotSupported
}
```

**Regression-test shape.** `services/observability/httpmid_test.go`
(`TestHTTPMiddleware_PreservesFlusher`) runs the middleware against a
handler that asserts `w.(http.Flusher)` and calls `Flush()`; the
assertion must succeed and the call must land. Ship this test alongside
every new middleware that wraps the writer — the plain `go build`
succeeds without it and the bug only shows at runtime on an SSE route.

**Audit trigger.** On ANY review that adds `r.Use(...)` or edits a type
in `services/observability/`, `apps/api/middleware.go`, or any file that
defines a `type <X> struct { http.ResponseWriter; ... }`, grep the file
for `Flush` and `Hijack`. Missing either is a bug even if the lint and
tests don't complain.

## Streaming routes stay OUT of the Timeout middleware group

Another chi-middleware trap that bites SSE: `middleware.Timeout(30 *
time.Second)` wraps the ResponseWriter in a chi-internal wrapper that
does NOT implement `http.Flusher`, AND it severs the connection at the
deadline mid-stream. The handler keeps running (persists the script
correctly) but the client sees a dead connection after the last delta
and before the terminal `replace`/`done` events.

**Current wiring** (`apps/api/main.go` ~ `/live/scripts/stream`):
streaming routes are registered BEFORE the `r.Group(func(r chi.Router)
{ r.Use(middleware.Timeout(30*time.Second)); ... })` block. Keep them
there. Every new SSE route (`/live/*/stream`, `/events/stream`, future
`:fromPrompt` variants) MUST be registered outside the Timeout group.
The handler's own `genCtx` is the bound — the chi timeout is a per-
request wall clock that doesn't understand long-tail streaming.

## Grepping to catch both in one pass

Before merging any PR that touches middleware or adds a streaming route:

```bash
# Writer wrappers missing Flush pass-through:
grep -rln -A20 'http.ResponseWriter$' services/ apps/api/ 2>/dev/null \
  | xargs -I{} sh -c 'grep -L "func.*Flush()" "{}"' | grep -v _test

# SSE routes incorrectly placed inside a Timeout group:
grep -nE 'live.*stream|events/stream' apps/api/main.go
# Then eyeball: is the line BEFORE the `middleware.Timeout` r.Use?
```
