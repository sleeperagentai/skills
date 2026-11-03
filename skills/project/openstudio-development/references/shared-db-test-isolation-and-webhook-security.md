# Two durable gotchas — surfaced on PRs #34 and #35

## 1. Shared-DB tests need a per-process workspace, not just scoped queries

**Symptom.** `apps/api` tests pass alone, pass serial, pass in default parallel. They FAIL only when a second `go test` binary runs against the same `openstudio` Postgres at the same moment (e.g. a reviewer re-running one package while the main suite is live, or `for m in ...; do (cd $m && go test); done` with concurrent subshells). Example failures:
```
--- FAIL: TestBackgroundSweeperFinishesAWholeSetWithNobodyWatching
    after sweeping: status=ready pending=1          (want pending=0)
--- FAIL: TestCompletingTheSetForAnOldInfluencerMakesOnlyTheMissingFive
    get = 404 influencer not found                   (the other binary's cleanup wiped it)
```

**Root cause.** `ws_demo` is a hard-coded constant across the test files. Both binaries create rows under the same workspace id, so:
- A sweeper call in test A picks up rows created by test B, polls them against test A's local fake vendor (unknown request id → `InProgress`), claims them under lease.
- A `t.Cleanup` `DELETE ... WHERE name LIKE 'T-inf-%'` wipes the other binary's rows mid-test.
- Asserts that "before the portrait exists, X returns 400" flip to 404 because the other binary already deleted the pending influencer.

**Half-fix that does NOT work.** Scoping the production query to a workspace (e.g. giving `PendingInfluencerWork` a workspace parameter and passing `ws_demo` in tests). Both binaries still agree on `ws_demo`, so they still trample each other.

**Real fix pattern.**
```go
// Package-level, once per process.
var (
    influencerTestWSOnce sync.Once
    influencerTestWS     string
)

func newInfluencerTest(t *testing.T) (*state, ...) {
    st := newCatalogTestState(t, true)
    influencerTestWSOnce.Do(func() {
        b := make([]byte, 8)
        _, _ = rand.Read(b)
        influencerTestWS = fmt.Sprintf("ws_test_inf_%x", b)
        if _, err := st.db.Pool.Exec(context.Background(),
            `INSERT INTO platform.workspaces (id, name, plan) VALUES ($1, $1, 'free')
             ON CONFLICT (id) DO NOTHING`, influencerTestWS); err != nil {
            t.Fatalf("seed test workspace: %v", err)
        }
    })
    // ...fund the ledger against influencerTestWS, cleanup scoped by workspace_id...
}
```
Then `sed -i 's/"ws_demo"/influencerTestWS/g'` across the test file, and manually fix the few string-fragment call-sites that need concatenation (URL path segments, object keys). Second-workspace tests derive from the primary: `wsB := influencerTestWS + "_b"` with its own INSERT.

**Reproducer-before-trust.** The fix is wrong until it survives this exact harness:
```bash
go test -c -o /tmp/<pkg>.test ./.
(/tmp/<pkg>.test -test.run '<flaky names>' -test.count=5 > /tmp/t1.log 2>&1 &)
(/tmp/<pkg>.test -test.run '<flaky names>' -test.count=5 > /tmp/t2.log 2>&1 &)
wait
grep -c FAIL /tmp/t1.log /tmp/t2.log  # must be 0 on both
```
Serial test runs, `-count=10` single-binary, `go test -race` all pass with the race present — only the two-binary configuration reveals it. Don't claim "fixed" without this reproducer.

**When to apply.** Any `apps/api` test package that writes to `content.*` AND calls a sweeper/finaliser that scans across workspaces. If a background goroutine in production reads rows unscoped, tests that trigger it from inside the binary need their own workspace.

---

## 2. Unauthenticated vendor webhooks: signal is a wake-up, not a source of truth

**Threat.** Higgsfield (and most generative providers — ElevenLabs, Suno, Minimax, Hailuo) do NOT sign webhooks. The ingress route lives outside auth so the vendor can POST without an API key. Attacker only needs a valid `rid=` query param (render id). Render ids leak via logs, vendor dashboards, URL copy-paste.

**The naive handler** extracts `status`, `video.url`, `error` from the body and signals the workflow with those fields. The workflow select-receives the signal, populates `terminal` from it, cancels the long poll, then feeds `terminal.VideoURL` straight into the Upload activity. A single POST like
```json
{"status":"completed","video":{"url":"https://attacker.example/evil.mp4"}}
```
replaces the user's render with the attacker's bytes.

**Correct posture** (pinned in `apps/api/cinematic_webhook_test.go`):
1. **Handler extracts ONLY `?rid=`.** Body is read-and-discarded under `http.MaxBytesReader(w, r.Body, 16<<10)`. Signal payload is `map[string]any{}` — empty wake-up.
2. **Workflow receiver cancels the long poll, then runs a FRESH authenticated short poll** on a NEW activity context derived from the workflow ctx (NOT from the just-cancelled pollCtx; a cancelled context taints its children). The authenticated poll's result is the only truth.
3. **Per-IP rate limit BEFORE body read.** `ratelimit.New(10, 3*time.Second)` keyed by `clientIP(r)` (`net.SplitHostPort(r.RemoteAddr)`). On 429, write `Retry-After: 3` and return WITHOUT signalling.
4. **Always 200** on legitimate shapes (vendor retries forever on non-2xx).

**Regression-test shape that catches a revert.** Three tests:
- `TestWebhookSignalIsOpaqueWakeUp` — POST hostile body with a sentinel string (`attacker.example`), fake temporal captures the signal payload, assert the string appears NOWHERE in it AND none of `status`/`videoURL`/`video`/`error`/`url` keys exist. The forbidden-key list is wider than the current threat so a lazy future change that stashes the body under a different key still trips.
- `TestWebhookBodyIsBounded` — POST a 1 MiB body, assert 200 without OOM and that exactly one signal landed.
- `TestWebhookRateLimit` — burst past capacity, assert 429 with `Retry-After` AND that NO signal was enqueued for the 429 call (capture-count assertion), and that a different IP is NOT blocked by the first IP's bucket.

**Fake-temporal shape for capture-based tests.**
```go
type capturingTemporal struct {
    mu      sync.Mutex
    signals []capturedSignal   // {WorkflowID, Signal, Payload}
}
func (c *capturingTemporal) SignalWorkflow(_ context.Context, wf, _ string, sig string, arg any) error {
    c.mu.Lock(); defer c.mu.Unlock()
    c.signals = append(c.signals, capturedSignal{wf, sig, arg})
    return nil
}
// Plus a waitFor(t, n) that polls up to a short deadline so the test
// doesn't flake on the goroutine that dispatches signals async.
```

**Reservation IDs in seed helpers.** `CreateRender(ctx, projID, ws, workflowID, reservationID)` enforces an FK on `reservation_id` when non-empty. In tests that don't care about billing paths, pass `""` — the column is NULL-safe. Passing `"res_test"` or similar WILL fail with `violates foreign key constraint "renders_reservation_id_fkey"`.

**When to apply.** Any new unauthenticated endpoint that lives outside the chi auth group — webhook ingresses, OAuth callbacks, public probe endpoints. Rate-limit first, body-size cap second, no-trust-of-body third.
