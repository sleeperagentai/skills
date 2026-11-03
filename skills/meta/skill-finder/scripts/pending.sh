#!/usr/bin/env bash
# List or forget PRs that skill-finder opened and that are still waiting for a merge.
# Usage: pending.sh --list | --forget <pr-number> | --add <pr> <url> <name> <branch>
set -u
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
sf_mkdirs
f="$SF_STATE_DIR/pending.json"; [ -f "$f" ] || echo '[]' > "$f"
case "${1:---list}" in
  --list)
    python3 -I - "$f" <<'PY'
import json, sys, subprocess
d = json.load(open(sys.argv[1]))
if not d:
    print("no pending PRs"); sys.exit(0)
for e in d:
    state = ""
    try:
        state = subprocess.run(["gh", "pr", "view", str(e["pr"]), "--repo", e.get("repo", "sleeperagentai/skills"), "--json", "state", "--jq", ".state"],
                               capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:  # noqa: BLE001
        state = "?"
    print(f"PR #{e['pr']}  {e.get('name','')}  {e.get('url','')}  created {e.get('created_at','')}  state={state or '?'}")
PY
    ;;
  --forget)
    python3 -I - "$f" "${2:?pr number}" <<'PY'
import json, sys
p, n = sys.argv[1:3]
d = [e for e in json.load(open(p)) if str(e.get("pr")) != n]
json.dump(d, open(p, "w"), indent=2); print(f"forgot PR #{n}")
PY
    ;;
  --add)
    python3 -I - "$f" "${2:?pr}" "${3:?url}" "${4:?name}" "${5:?branch}" "$SF_REPO" <<'PY'
import json, sys, datetime
p, pr, url, name, branch, repo = sys.argv[1:7]
d = json.load(open(p))
d = [e for e in d if str(e.get("pr")) != pr]
d.append({"pr": int(pr), "url": url, "name": name, "branch": branch, "repo": repo, "created_at": datetime.datetime.now().isoformat(timespec="seconds")})
json.dump(d, open(p, "w"), indent=2)
PY
    ;;
  *) sf_die "usage: pending.sh --list | --forget <pr> | --add <pr> <url> <name> <branch>" 1;;
esac
