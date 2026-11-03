# Health & readiness probes across services

Shared contract for `/healthz` + `/readyz` on every long-running service
(`apps/api`, `apps/worker-core`, `apps/worker-render/motion-renderer`,
`apps/scheduler`). Load this before adding a probe to a new service or
changing the shape on an existing one.

## Payload shape (pinned)

Every service's /readyz MUST return the exact shape `apps/api/healthz.go`
ships:

```json
{
  "ok": true,
  "service": "<name>",
  "version": "<version>",
  "checks": {
    "<dep>": {"status": "ok|fail|timeout|disabled", "detail": "..."}
  }
}
```

- `/healthz` is cheap liveness: 200 whenever the process is up, no deps
  touched. k8s restarts a healthy pod if `/healthz` depends on a slow dep.
- `/readyz` is a 2s-per-check dependency fan-out. 503 only when a dep
  returned `fail` or `timeout`. `disabled` (nil dep, feature off by config)
  does NOT fail readiness — otherwise a dev-mode in-memory boot always
  503s and the probe is useless.
- Default ports sit adjacent to the api's :4000 so operators remember
  the pattern: worker-core :4100, worker-render :4101, scheduler :4102.
  Each service's `<NAME>_HEALTH_ADDR=""` env disables the server for
  one-shot runs or test harnesses.

## Drain-aware readiness (standing rule)

A service that is shutting down must 503 /readyz BEFORE it tears down
real work. Without this the LB keeps routing to a departing pod for
one scrape interval. Pattern that works for both Go and Node:

1. On signal, flip an `isDraining` atomic/boolean. /readyz checks it
   first and short-circuits to `{status: "fail", detail: "draining"}`.
2. Drain the real worker (`w.Stop()` in Go, `await worker.shutdown()` in
   Node) while the probe server stays up.
3. Shut the probe server down LAST, with a bounded timeout.

Closing the probe server before draining makes probes see
`connection refused` instead of 503 draining — dashboards go blind at
the moment they're most needed.

## Per-service checks that are load-bearing

- **worker-core (Go)**: `temporal` check alone is not enough. A worker
  whose `w.Run()` goroutine has exited (panic, Stop, SDK error) will
  still report temporal=ok as long as the Temporal frontend is reachable.
  Track a `workerRunning atomic.Bool` set true at the start of the run
  goroutine and false in its deferred cleanup; expose it as `checks.worker`.
- **worker-render (Node)**: `worker.getState()` is the Temporal SDK's
  lifecycle. The ready set must be `{INITIALIZED, RUNNING}` — probes
  can land between `Worker.create()` and `worker.run()` on a healthy
  pod, and a strict `=== 'RUNNING'` check 503s every kubelet startup
  probe for a few hundred ms. `STOPPING / DRAINING / DRAINED / STOPPED
  / FAILED` all fail so drain still 503s correctly.
- **scheduler (Go)**: no Temporal, no storage. The real liveness signal
  is "a job tick has happened recently". Track a single `jobHeartbeat
  atomic.Int64` bumped at the top of the per-job `run()` loop (BEFORE
  `j.Run()` — a job that panics mid-execution still signals the loop
  is alive). Zero heartbeat on cold boot stays `disabled` (grace window)
  rather than fail. Threshold: 2× the shortest must-tick interval, so a
  one-cycle miss does not 503.
- **api**: the shipped reference. Do not drift its shape.

## Node-specific pitfalls

- **`http.Server.listen` with no `error` listener crashes the process on
  EADDRINUSE / EACCES** — exactly when health is supposed to be the
  diagnostic signal. Attach `srv.on('error', (err) => { log.error({err},
  'health server error'); })` so the diagnostic server never takes the
  real worker down with it.
- **`addr.lastIndexOf(':')` mangles `[::1]:port`** (returns `host='[::1]'`
  including brackets, which Node refuses with EINVAL). And
  `Number('')`/`Number('abc')` → `NaN` → Node silently binds a random
  port. Ship a `parseListenAddr()` that matches `/^\[([^\]]+)\]:(\d+)$/`
  for the IPv6 bracketed form, splits on last `:` otherwise, and
  validates `Number.isInteger(port) && 0 <= port <= 65535` and throws
  on garbage. `port=0` is intentional (OS picks a free port, test
  harnesses use it).
- **`withTimeout` must `clearTimeout` in a `finally`** or every scrape
  during a Temporal outage leaks a dangling timer; the event loop also
  stays alive for up to 2s past shutdown. The resolved-promise branch
  does not clean up on its own.
- **Signal-handler functions must be async + awaited.** `worker.shutdown()`
  and `healthSrv.close()` both return promises. A sync handler that
  calls them unawaited races `connection.close()` and drops errors.

## Go-specific pitfalls

- **A probe-held `*store.Store` must be `Close()`d on signal exit** or
  the pgx pool is dropped without draining in-flight connections.
- **Package-level atomics (`jobHeartbeat`, `draining`) leak across test
  cases in the same binary.** Add a `resetGlobals(t)` helper with
  `t.Cleanup` that zeroes them, and call it at the top of every test
  that reads either.
- **`client.Client.CheckHealth` is NOT variadic in `go.temporal.io/sdk/client`.**
  Signature is `CheckHealth(ctx, *CheckHealthRequest) (*CheckHealthResponse, error)`.
  A fake Temporal client declaring `_ ...grpc.CallOption` fails to
  satisfy the interface — the test won't compile, and the error
  ("wrong type for method CheckHealth") doesn't mention the arity. Pin
  the fake's signature to the real one.

## Verification recipe

1. Unit tests per service exercise: disabled-dep (200 all `disabled`),
   failing-dep (503 with `detail` populated), timeout path
   (`context.DeadlineExceeded` → `status: "timeout"`), drain flag
   (503 with `detail: "draining"`), and the service-specific liveness
   check (`workerRunning=false`, `getState='STOPPING'`, stale heartbeat).
2. After rebuild, live-check the whole stack in one pass:

   ```sh
   for p in 4000 4100 4101 4102; do
     printf '%s: ' "$p"
     curl -s "localhost:$p/readyz" | jq -c '{ok, service, checks}'
   done
   ```

3. Negative-path live-prove is OPTIONAL — tearing down the user's live
   Postgres/MinIO/Temporal to force 503 is not worth it when unit tests
   already cover the fail branches honestly.
