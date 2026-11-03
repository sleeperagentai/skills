#!/usr/bin/env bash
# Probe every component in the stack. Allows a warm-up window because
# Tempo's live-store and Pyroscope's ingester both have a mandatory
# "waiting Ns after being ready" settle period after process start.
set -euo pipefail

WARMUP="${WARMUP:-20}"
echo "waiting ${WARMUP}s for stack warm-up..."
sleep "$WARMUP"

probes=(
  "Tempo:http://localhost:3200/ready"
  "Loki:http://localhost:3100/ready"
  "Prometheus:http://localhost:9090/-/ready"
  "Pyroscope:http://localhost:4040/ready"
  "OTelcol:http://localhost:13133/"
  "Grafana:http://localhost:3030/api/health"
)

fail=0
for p in "${probes[@]}"; do
  name="${p%%:*}"; url="${p#*:}"
  if curl -sfm 3 -o /dev/null "$url"; then
    printf 'OK   %-12s %s\n' "$name" "$url"
  else
    printf 'FAIL %-12s %s\n' "$name" "$url"
    fail=1
  fi
done
exit "$fail"
