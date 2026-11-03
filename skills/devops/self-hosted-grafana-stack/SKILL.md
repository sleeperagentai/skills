---
name: self-hosted-grafana-stack
description: Boot Grafana+Tempo+Loki+Prom+Pyroscope+otelcol natively.
---

# Self-hosted Grafana observability stack (native, no Docker)

The LGTM+P stack (Loki, Grafana, Tempo, Mimir/Prometheus, Pyroscope) + OTel Collector, booted as plain binaries on macOS/Linux. Every component has shipped a breaking config change in the last two majors; the defaults the docs show rarely match the binary you just downloaded. This skill is the compressed set of fixes.

## Procedure

1. **Pick binary sources, not Homebrew, for Tempo / Loki / Pyroscope / otelcol-contrib.** Only Grafana and Prometheus are in homebrew-core. The others publish signed tarballs on their GitHub releases. On darwin/arm64, Tempo currently has NO v2.x build — only v3.x releases carry the arm64 asset. Query `GET /repos/<org>/<repo>/releases` and filter `assets[].name` for `darwin.*arm64` before you choose a version.

2. **Lay binaries under `~/.<project>/obs/bin/`** and reference them by absolute path from the launcher script. Do not symlink into `/usr/local/bin` — version pinning gets lost and `brew upgrade` can clobber.

3. **Boot order: Tempo → Loki → Prometheus → Pyroscope → OTel Collector → Grafana.** The Collector must come up AFTER its backends or its first flush retries noisily; Grafana last so datasource health checks pass on first paint.

4. **Health-probe every component with a 20s warm-up window** before declaring the stack up. Pyroscope and Tempo both report `503 ... waiting Ns after being ready` for 10–20s after process start — that is their quorum settle, not a failure. Readiness URLs: Tempo `/ready`, Loki `/ready`, Prometheus `/-/ready`, Pyroscope `/ready`, otelcol `:13133/`, Grafana `/api/health`. Use `scripts/health-check.sh`.

5. **Verify the pipeline end-to-end before writing SDK code.** POST a hand-crafted OTLP JSON to `:4318/v1/traces` and `:4318/v1/logs` and expect `HTTP 200`. Use `scripts/otlp-smoketest.sh`.

6. **Stop the stack via pidfile + `pkill -f "<obs-bin-dir>/tempo"`.** Tempo (and sometimes Pyroscope) spawn child goroutines that hold listener FDs after the parent is signalled; a pidfile-only teardown leaves `:3200` bound and the next `up` run fails with `address already in use`.

## Always-on rules

- **Grafana must not run on `:3000`.** Next.js, CRA, and basically every JS dev server own `:3000` by default. Set `[server] http_port = 3030` in `grafana.ini`.

- **Single OTel ingest surface.** All services export to the Collector on `:4317` (gRPC) or `:4318` (HTTP). The Collector fans out to the backends. Never let a service talk directly to Tempo/Loki/Prometheus — you lose the ability to add processors (scrub, batch, resource) later without redeploying every service.

- **Collector env-var defaults use `${env:VAR:-default}` syntax.** `${env:VAR}` with VAR unset is a hard error on startup (empty-string, not fallthrough). Any attribute referenced from env must either be guaranteed set or carry a `:-fallback`.

- **Prometheus retention is a CLI flag, not a config key.** `--storage.tsdb.retention.time=15d` on the command line. Putting `storage.tsdb.retention.time:` in `prometheus.yaml` is silently ignored or rejected.

- **Prometheus needs `--web.enable-remote-write-receiver`** before the Collector's `prometheusremotewrite` exporter will succeed. Without it the Collector logs look fine and metrics vanish.

- **otelcol-contrib removed the `loki` exporter.** Replace with `otlphttp/loki` pointing at `http://localhost:3100/otlp` (Loki 3's native OTLP endpoint). The old `loki` exporter name fails config parse on current contrib builds.

- **Tempo 3.x monolithic (`target: all`) rejects `ingester:` and `compactor:` top-level blocks.** Those were valid in 2.x; the Project Rhythm refactor moved them. The authoritative single-binary YAML lives at `example/docker-compose/single-binary/tempo.yaml` on the matching version tag — fetch THAT, don't trust blog posts or the main docs page.

- **Tempo 3.x hardcodes `/var/tempo` as the live-store / scheduler / shutdown-marker / block-builder path even when `storage.trace.local.path` is set.** Pass four CLI flags: `-live-store.wal.path=<dir>`, `-live-store.shutdown_marker_dir=<dir>`, `-block-builder.wal.path=<dir>`, `-backend-schedulerbackend-scheduler.local-work-path=<dir>` (the double-prefix is not a typo — Tempo registers it that way). Omitting any produces `permission denied: /var/tempo` on first write.

- **Pyroscope v2 defaults to `v1-v2-dual` architecture, which needs a distributed metastore on `:9095`.** For a single-process local deploy pass `-architecture.storage=v1 -write-path=ingester`. Without both, you get `write-path=ingester is required for v1 storage layer` or silent 503s on `/ready`. The `compactor.blocks_retention_period` and `usage_stats` fields were also removed from the parsed config in v2 — strip them if copied from older examples.

- **Keep all component state under one `OBS_HOME/<component>/` tree.** Backups, `rm -rf` cleanup, and port-collision debugging all get easier when Tempo's WAL, Loki's chunks, Prometheus's TSDB, Pyroscope's data, and Grafana's SQLite share a parent.

- **Pick an obs base port that avoids MinIO.** MinIO's defaults are `:9000` (API) + `:9001` (console), both hardcoded across the ecosystem. If you want a contiguous obs band on 9xxx, start at `:9040` or `:9100`, never `:9000`. The whole stack renumbers cleanly on a `base + k*10` grid (Grafana base+0, Prometheus base+10, Loki base+20, Tempo base+30, Pyroscope base+40, OTel Collector base+50 for OTLP gRPC + 51 HTTP + 52 health).

- **When Grafana queries a Postgres datasource co-located with an app DB, REVOKE CONNECT FROM PUBLIC on the app DB.** Postgres grants `CONNECT` to `PUBLIC` by default, so your obs roles can open a session on the customer DB even with zero table grants. Fix in the obs provisioner, verify at runtime with `psql -U <obs_reader> -d <customer_db>` — it must fail with `permission denied for database`. See `references/grafana-postgres-datasource.md`.

- **Point Grafana at the SELECT-only reader role, never the owner.** Grafana's long-lived connection pool means a compromised Grafana must not be able to DELETE audit rows. Retention jobs get their own owner DSN.

## Pitfalls

- **Go OTel gRPC exporter's `WithEndpoint` wants bare `host:port`, not `http://host:port`.** The OTEL spec env var `OTEL_EXPORTER_OTLP_ENDPOINT` is URL-shaped (`http://localhost:4317`), so users and docs pass it along verbatim — then `otlptracegrpc.New(ctx, otlptracegrpc.WithEndpoint(url))` fails at first export with `too many colons in address: http://host:port:443` because the gRPC resolver treats the whole thing as a target string. In the SDK bootstrap, strip the scheme before `WithEndpoint`: `endpoint = strings.TrimPrefix(strings.TrimPrefix(url, "https://"), "http://"); endpoint = strings.TrimSuffix(endpoint, "/")`. OTLP HTTP exporters accept the URL form — this trap is gRPC-only.

- **An audit/instrumentation RoundTripper only captures callers that actually use it.** Shipping `httplog.Wrap()` + the writer + the DB is step one of two; step two is grep `grep -rn 'http.Client{\|http.DefaultTransport\|http.DefaultClient' <app-source>` and swap each raw client for one that routes through the audit transport. Without step two, every dashboard panel reads `0 rows` while the pipeline looks healthy — infrastructure sitting idle is the most common instrumentation failure, not a transport bug.

- **Inject the audited client through a factory with a MANDATORY per-caller label, not through a global package-level transport.** A `var Transport http.RoundTripper` shared by every provider in an AI gateway or outbound subsystem is the convenient fix but the wrong one: every audit row then carries `peer="ai-gateway"` and the dashboard can't tell Anthropic flakes from OpenAI flakes from a local inference server being down — which is the single most useful filter in a vendor audit log. Expose `NewHTTPClient(peer string, timeout time.Duration) *http.Client` on the subsystem package; each provider's constructor passes its own stable label (`anthropic`, `openai-tts`, `elevenlabs`, `local-textgen`, …); the main binary swaps the factory at boot so the returned clients wrap `httplog.Wrap(..., Peer: peer, …)`. Panic on a blank peer so a new provider cannot ship without declaring its label. The factory is also the natural place to carve out noise — provider liveness probes (`Reachable()` style `/health` or `/models` GETs that fire every router decision) should bypass it, otherwise the audit log drowns the real traffic in trivial 200s.

- **Don't copy monolithic Tempo configs from community blog posts — nearly all show 2.x shape.** Use the GitHub tag's `example/docker-compose/single-binary/tempo.yaml` for the exact binary version. A 2.x config boots on a 3.x binary without complaint, then dies when it tries to flush a block.

- **Don't bind Collector OTLP and Tempo OTLP to the same port.** The Collector owns `:4317`/`:4318` (that's what SDKs point at). Tempo's internal OTLP receiver must move to `:4327`/`:4328`; the Collector forwards there via `otlp/tempo`. Shared ports produce `bind: address already in use` on one of them, non-deterministically.

- **Don't trust the first `/ready` probe within 10s of boot.** Tempo's live-store needs to flush a startup marker; Pyroscope's ingester has a mandatory 15s ready-delay. Build the warm-up into the launcher, not into tests.

- **Don't use Homebrew's `grafana` wrapper without `--homepath`.** The wrapper assumes `/opt/homebrew/opt/grafana/share/grafana` as its asset root; invoking bare `grafana server --config ...` without the flag fails to find `public/views/index.html` and renders a blank page.

- **Downstream read emptiness right after a successful push is NOT a pipeline failure.** `curl POST /v1/traces` returns 200, then `GET /api/search` on Tempo returns `traces: []` for 10–30s while the block is still in the WAL. Same for Loki with log-label indexing. Wait a flush interval before concluding the pipeline is broken.

## Reference files

- `references/version-pins.md` — Known-good Darwin arm64 versions and the config-shape quirks that bite each.
- `templates/tempo-single-binary-3x.yaml` — Validated Tempo 3.x monolithic config.
- `templates/otelcol-contrib.yaml` — Collector config: OTLP in, Tempo/Loki/Prometheus out, scrub + resource processors.
- `templates/pyroscope-v2-single.yaml` — Pyroscope v2 config paired with the v1-storage CLI flags.
- `scripts/otlp-smoketest.sh` — POST a trace + a log via OTLP HTTP; expect 200 from both.
- `scripts/health-check.sh` — Probe all six endpoints with 20s warm-up.
