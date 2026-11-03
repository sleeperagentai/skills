# apps/api structural-lint traps

The `apps/api` package carries a handful of file-walking tests that enforce
conventions no compiler can see. They match on literal source patterns, so a
handler that compiles and runs correctly can still fail CI on a naming
convention or an idiom. Keep this list handy before writing new handlers
under `apps/api`, and before patching an existing one with code copy-pasted
from outside the package.

## `unauth_sweep_test.go` — bans bare `if p == nil {`

Regex: `if\s+p\s*==\s*nil\s*\{` (literal, in non-test `.go` files).

**Why it exists.** `principalFrom(r.Context())` returns a non-nil
`*auth.Principal` with zero-value fields when the session is missing or
malformed. A bare `if p == nil { return }` guard never fires, so an
unauthenticated request flows straight into the handler and reaches the
store with `WorkspaceID == ""`. The structural test refuses the pattern
so the bug cannot be reintroduced.

**The correct idiom** (used by `social.go`, `publications.go`,
`influencers.go`, and every reviewed handler):

```go
func (s *state) handleX(w http.ResponseWriter, r *http.Request) {
    princ := requirePrincipal(w, r)   // helper lives in social.go
    if princ == nil {                 // real nil; writes 401 then returns
        return
    }
    // ... use princ.UserID / princ.WorkspaceID
}
```

`requirePrincipal` already writes a 401 and returns nil on empty
`UserID` / `WorkspaceID`; the handler just needs the early return. For
board-restricted handlers the helper is `s.requireBoardPrincipal` with
the same contract.

**Trap.** Subagents writing new handlers routinely default to `p` out
of brevity (one char vs five) and the lint fires on every handler at
once — 30+ matches in a single file. The literal regex matches ONLY
the variable name `p`; `princ`, `princ := s.requireBoardPrincipal(...)`,
`user`, etc. are fine.

**Mitigations.**
- When dispatching a subagent to write new handlers in `apps/api`, state
  the variable-name rule in `context`: "name the principal variable
  `princ`; `p` fails `unauth_sweep_test.go`". Add a one-line sample
  showing the `requirePrincipal` + `if princ == nil` pattern.
- After-the-fact rescue when every `p` in a new file is the principal:
  `perl -i -pe 's/\bp\b/princ/g' apps/api/<file>.go`, then build. Verify
  no non-principal uses of a bare `p` existed before running it
  (`grep -nE '\bp\b' apps/api/<file>.go | grep -v -E 'p\.(UserID|WorkspaceID|KeyID)'`).
- Running `go test ./apps/api/... -count=1 -run TestNoBareNilAuthGuards`
  isolates the lint for fast feedback.

## Related

`apps/api/render_path_test.go` is another structural test — it refuses
multiple dispatch paths for a render. The pattern (walking the AST,
skipping comments, exempting one owning package) is identical and the
same class of failure applies: refactors that touch render-dispatch
wiring can trip it even when behaviour is unchanged. If you add a new
structural test, drop a deliberate violation into the package and
confirm the test fails with the message you expect before shipping it;
structural tests are the easiest to write vacuously.

## ResponseWriter-wrapping middleware MUST pass through Flusher and Hijacker explicitly

Any chi/net-http middleware that wraps `http.ResponseWriter` to capture
status codes, inject headers, or record metrics (`services/observability.HTTPMiddleware`'s
`statusRecorder` is the one in this repo) MUST implement `Flush()` and
`Hijack()` as method pass-throughs on the wrapper struct. Embedding the
ResponseWriter is NOT enough:

```go
type wrapper struct { http.ResponseWriter; status int }

func (w *wrapper) WriteHeader(code int) { ... }

func (w *wrapper) Flush() {
    if f, ok := w.ResponseWriter.(http.Flusher); ok { f.Flush() }
}

func (w *wrapper) Hijack() (net.Conn, *bufio.ReadWriter, error) {
    if h, ok := w.ResponseWriter.(http.Hijacker); ok { return h.Hijack() }
    return nil, nil, http.ErrNotSupported
}
```

Why: Go's type assertion `w.(http.Flusher)` checks the WRAPPER type for
a `Flush()` method, not the embedded field. Embedding is composition,
not promotion of interface satisfaction — the inner Flush is reachable
via `w.ResponseWriter.Flush()`, but a bare type assertion returns
`ok=false`. The failure mode is every SSE handler behind the middleware
(e.g. `/api/v1/live/scripts/stream`) returning a 500 `streaming is not
supported on this connection` the instant a user hits the Script step
of the create wizard. Same shape bites WebSocket upgrades (missing
`Hijacker`).

Regression guard: an httptest-based test that drives the middleware
with a handler which type-asserts `w.(http.Flusher)` and asserts the
`Flush()` call actually lands. `httptest.ResponseRecorder` implements
`Flusher`, so the test is cheap. See
`services/observability/httpmid_test.go`.
