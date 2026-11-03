# Concurrent resource slots across goroutine handoffs (Go)

Topical reference loaded by `openstudio-development` when adding a per-workspace / per-user cap that is acquired in an HTTP handler and released at terminal state inside a background goroutine (concurrent-render cap, in-flight API-key hold, long-running export slot).

## The ownership transfer

The handler must TAKE the slot before any expensive work (DB lookup, pricing, credit reservation) so a client in a loop gets 429 cheaply. On every error path the slot has to come back. On the one success path, ownership transfers to a goroutine whose own defer release the slot when the workflow finishes.

Two defers (handler + goroutine) over-release and let the next render bypass the cap. Zero defers on the handler side leaks the slot on any 4xx between gate and goroutine launch. The ownership-transfer pattern is:

```go
func (s *state) handleRenderProject(w http.ResponseWriter, r *http.Request, kindID string) {
    p := principalFrom(r.Context())
    // ... scope + auth checks ...

    // Acquire BEFORE any DB/pricing work — a looping client must 429
    // cheaply, not after a round-trip.
    if !s.renderGate.gate(w, p.WorkspaceID) {
        return
    }
    released := false
    defer func() {
        if !released {
            s.renderGate.release(p.WorkspaceID)
        }
    }()

    // ... DB lookup, pricing, credit reservation; every error path
    // falls through to the handler-level defer and returns the slot.

    // Ownership transfer: at the one success path, flip released=true
    // BEFORE `go worker()` so the handler defer skips. The goroutine
    // now owns the slot and MUST release it on terminal state.
    if wfID, runID, err := s.temporal.StartRender(ctx, wfIn); err != nil {
        released = true // ownership → simulateRender's defer
        go s.simulateRender(rec)
    } else {
        released = true // ownership → awaitTemporalResult's defer
        go s.awaitTemporalResult(rec, wfID, runID)
    }
}

func (s *state) simulateRender(rec *renderRec) {
    defer s.renderGate.release(rec.WorkspaceID) // single owner on terminal state
    // ...
}
```

Every handler that launches the same background work MUST follow the same shape, pointing at the same slot gate: `handleRenderProject`, `handleRetryRender`, `handleNextEpisode`, materialize-with-render — four sites, one pattern.

## The slot gate itself

```go
type concurrentRenderGate struct {
    cap    int32
    mu     sync.Mutex
    counts map[string]*int32 // per-workspace counter
}

func (g *concurrentRenderGate) tryAcquire(workspaceID string) bool {
    if g == nil || g.cap <= 0 { return true } // nil-safe + disabled
    g.mu.Lock()
    c, ok := g.counts[workspaceID]
    if !ok { var n int32; c = &n; g.counts[workspaceID] = c }
    g.mu.Unlock()
    for {
        cur := atomic.LoadInt32(c)
        if cur >= g.cap { return false }
        if atomic.CompareAndSwapInt32(c, cur, cur+1) { return true }
    }
}
```

**Release MUST clamp at zero** — an accidental double-release (goroutine-side defer firing twice; handler-side flag flipping late) would otherwise push the counter negative and let the next N renders bypass the cap. CAS-loop with `if cur <= 0 { return }`:

```go
func (g *concurrentRenderGate) release(workspaceID string) {
    if g == nil { return }
    g.mu.Lock(); c := g.counts[workspaceID]; g.mu.Unlock()
    if c == nil { return }
    for {
        cur := atomic.LoadInt32(c)
        if cur <= 0 { return }
        if atomic.CompareAndSwapInt32(c, cur, cur-1) { return }
    }
}
```

Lock the map insert but do the increment with atomics so the map lock isn't held across the (short) CAS loop. Over-admit by at most 1 per workspace from a wide CAS race — acceptable, and still bounded.

## Boot config + the quiet-disable foot-gun

- Env override to pause (`RENDER_CONCURRENT_CAP`) — zero or negative DISABLES the gate (nil-safe acquires always succeed). Log a WARN at boot when disabled: `slog.Warn("concurrent-render gate DISABLED — RENDER_CONCURRENT_CAP<=0; any workspace can monopolise the render queue", "cap", renderCap)`. Silent-disable is ambiguous and a config typo must be visible in production logs.
- Nil receiver (`var g *concurrentRenderGate; g.gate(...)`) must be a cheap no-op — lets tests opt out without threading a non-nil instance through every helper.

## Response contract on 429

Write `Retry-After` as an advisory integer seconds, and include `activeRenders` + `maxConcurrent` in the error details so the client can show "You have 5 renders in progress; wait for one to finish." never a bare "too many requests." The exact-time-to-availability depends on the workflow runtime (seconds for a motion-graphics preview, minutes for a cinematic render), so `Retry-After` is a nudge, not a promise.

## Tests to lock the invariants

Unit tests do not need a live stack. Pure-function assertions:

- First `cap` acquires succeed; `cap+1`th fails. Different workspaces are independent.
- Release decrements; after `release`, a fresh acquire succeeds.
- Over-release clamps at zero: three release calls on a zero counter leaves it at zero, and the next acquire still succeeds.
- Nil-receiver gate always admits.
- Concurrent-admission race: 200 goroutines hammer `tryAcquire` with `cap=10`, admitted count must equal EXACTLY 10. Run under `-race` so the CAS loop is exercised against the data-race detector.
- `gate(w, workspaceID)` writes 429 + `Retry-After` header on the over-cap path.

And for each handler that uses the gate: a test with `cap=1` where the second concurrent request within the cap's horizon returns 429.
