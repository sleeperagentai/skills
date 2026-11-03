#!/usr/bin/env bash
# Push one hand-crafted OTLP trace and one log to the local Collector.
# Both should return HTTP 200 within a second of the Collector being ready.
# Downstream read-side (Tempo /api/search, Loki /query_range) may lag by one
# flush interval; expect empty results for ~10-30s on a cold stack — that is
# normal, not a failure.
set -euo pipefail

OTLP_HTTP="${OTLP_HTTP:-http://localhost:4318}"

TRACE_JSON='{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"obs-smoketest"}}]},"scopeSpans":[{"scope":{"name":"smoketest"},"spans":[{"traceId":"5b8aa5a2d2c872e8321cf37308d69df2","spanId":"051581bf3cb55c13","name":"obs-pipeline-smoketest","kind":1,"startTimeUnixNano":"1759772000000000000","endTimeUnixNano":"1759772001000000000","status":{"code":1}}]}]}]}'

LOG_JSON='{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"obs-smoketest"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"1759772000000000000","severityNumber":9,"severityText":"INFO","body":{"stringValue":"obs pipeline smoketest log line"}}]}]}]}'

code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  --data-binary "$TRACE_JSON" "$OTLP_HTTP/v1/traces")
echo "trace push: HTTP $code"
[[ "$code" == "200" ]] || exit 1

code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  --data-binary "$LOG_JSON" "$OTLP_HTTP/v1/logs")
echo "log push:   HTTP $code"
[[ "$code" == "200" ]] || exit 1

echo "OK: Collector accepted trace + log on $OTLP_HTTP"
