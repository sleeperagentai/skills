# Known-good versions on Darwin arm64 (update when verified)

| Component | Version pinned | Why not newer / older |
|---|---|---|
| Tempo | v3.1.0 | Only v3.x ships a `darwin_arm64` build; 2.x is linux-only on arm64. The 3.1.0 single-binary example YAML on the v3.1.0 tag is the authoritative config shape. |
| Pyroscope | v2.3.1 | v2.x is a full redesign of the ingest path. Must boot with `-architecture.storage=v1 -write-path=ingester` to avoid the metastore requirement. v0.x/1.x configs are not forward-compatible. |
| Loki | 3.x (latest release) | Loki 3's `/otlp` endpoint is what the Collector targets — do not drop below 3.0 or the `otlphttp/loki` exporter 404s. |
| otelcol-contrib | 0.100+ | Any contrib build after the `loki` exporter removal (~0.100). If you must use an older build, swap `otlphttp/loki` back for `loki:` with `endpoint: /loki/api/v1/push`. |
| Prometheus | brew current (3.x) | 3.x needs `--web.enable-remote-write-receiver` explicitly; 2.x had it default-on. |
| Grafana | brew current | Pin `[server] http_port = 3030` to avoid the `:3000` Next.js clash. |

## Finding the right asset URL quickly

```sh
curl -sfL "https://api.github.com/repos/grafana/tempo/releases?per_page=20" \
  | python3 -c "import json,sys;[print(r['tag_name'],a['name'],a['browser_download_url']) for r in json.load(sys.stdin) for a in r['assets'] if 'darwin' in a['name'].lower() and 'arm64' in a['name'].lower()]"
```

Swap `grafana/tempo` for `grafana/pyroscope`, `grafana/loki`, `open-telemetry/opentelemetry-collector-releases` as needed. If no `darwin.*arm64` rows print for your chosen tag, that version has no arm64 build — pick a different tag before anything else.
