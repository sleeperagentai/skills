#!/usr/bin/env bash
# Wait for a pull request on the skills repo to be merged.
# Usage: wait-for-merge.sh <pr-number|url> [--interval 300] [--timeout 3600] [--chunk SEC] [--once] [--repo owner/repo]
# The deadline is shared across invocations (state/pr-<n>.deadline), so chunked calls add up to one timeout.
# Exit: 0 merged | 2 closed without merge | 3 timeout | 4 gh kept failing | 5 chunk elapsed, still open | 130 interrupted
set -u
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
sf_require gh
pr="${1:-}"; [ -n "$pr" ] || sf_die "usage: wait-for-merge.sh <pr-number|url> [--interval 300] [--timeout 3600] [--chunk SEC] [--once]" 1
shift
interval=300; timeout=3600; chunk=0; once=0; repo="$SF_REPO"
while [ $# -gt 0 ]; do case "$1" in
  --interval) interval="$2"; shift 2;; --timeout) timeout="$2"; shift 2;; --chunk) chunk="$2"; shift 2;;
  --once) once=1; shift;; --repo) repo="$2"; shift 2;; *) shift;; esac; done
sf_mkdirs
num=$(printf '%s' "$pr" | sed -E 's#.*/pull/([0-9]+).*#\1#; s/^#//')
deadline_file="$SF_STATE_DIR/pr-$num.deadline"
now=$(sf_now)
if [ -f "$deadline_file" ]; then deadline=$(cat "$deadline_file"); else deadline=$(( now + timeout )); echo "$deadline" > "$deadline_file"; fi
start=$(( deadline - timeout )); chunk_end=$(( now + chunk ))
trap 'sf_log "interrupted; deadline kept"; exit 130' INT TERM

name=$(python3 -I -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for e in d:
        if str(e.get("pr"))==sys.argv[2]: print(e.get("name","")); break
except Exception: pass' "$SF_STATE_DIR/pending.json" "$num" 2>/dev/null)

fails=0
while :; do
  info=$(gh pr view "$num" --repo "$repo" --json state,mergedAt,mergeCommit,url,isDraft 2>/dev/null)
  if [ -z "$info" ]; then
    fails=$((fails+1)); [ "$fails" -ge 3 ] && sf_die "gh pr view failed 3 times in a row (network or auth)" 4
  else
    fails=0
    state=$(sf_json_get "$info" state)
    case "$state" in
      MERGED)
        sha=$(sf_json_get "$info" mergeCommit.oid)
        rm -f "$deadline_file"
        python3 -I - "$SF_STATE_DIR/pending.json" "$num" <<'PY' 2>/dev/null
import json,sys
p,n=sys.argv[1:3]
try: d=json.load(open(p))
except Exception: d=[]
d=[e for e in d if str(e.get("pr"))!=n]
json.dump(d,open(p,"w"),indent=2)
PY
        echo "MERGED pr=$num sha=$sha name=$name"
        exit 0;;
      CLOSED)
        rm -f "$deadline_file"; echo "CLOSED pr=$num (closed without merging)"; exit 2;;
    esac
  fi
  now=$(sf_now)
  [ "$once" = 1 ] && { echo "OPEN pr=$num elapsed=$(sf_hms $((now-start))) remaining=$(sf_hms $(( deadline>now ? deadline-now : 0 )))"; exit 5; }
  if [ "$now" -ge "$deadline" ]; then
    rm -f "$deadline_file"
    echo "TIMEOUT pr=$num after $(sf_hms $timeout). The PR is still open."
    echo "When it has been merged, run either of:"
    echo "  npx -y skills add $repo --skill ${name:-<skill-name>} -g -y"
    echo "  bash \"\$SKILL_DIR/scripts/wait-for-merge.sh\" $num --once   # re-check, then install"
    exit 3
  fi
  if [ "$chunk" -gt 0 ] && [ "$now" -ge "$chunk_end" ]; then
    echo "OPEN pr=$num elapsed=$(sf_hms $((now-start))) remaining=$(sf_hms $((deadline-now))) (chunk done, call again)"
    exit 5
  fi
  sleep_for=$interval
  [ $(( deadline - now )) -lt "$sleep_for" ] && sleep_for=$(( deadline - now ))
  [ "$chunk" -gt 0 ] && [ $(( chunk_end - now )) -lt "$sleep_for" ] && sleep_for=$(( chunk_end - now ))
  [ "$sleep_for" -lt 1 ] && sleep_for=1
  printf '[%s] PR #%s open; elapsed %s of %s; next check in %ss\n' "$(date +%H:%M:%S)" "$num" "$(sf_hms $((now-start)))" "$(sf_hms $timeout)" "$sleep_for" >&2
  sleep "$sleep_for"
done
