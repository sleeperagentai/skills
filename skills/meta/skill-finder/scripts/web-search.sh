#!/usr/bin/env bash
# Search the wider skills ecosystem. Usage: web-search.sh "<query>" [--limit 10] [--owner X]
# Output: JSON array [{source:"owner/repo", name, installs, stars, skills_sh, github}] sorted by installs, stars.
# Exit 3 when nothing found.
set -u
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
sf_require python3 curl
q="${1:-}"; [ -n "$q" ] || sf_die "usage: web-search.sh \"<query>\" [--limit N] [--owner X]" 1
shift
limit=10; owner=""
while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2;; --owner) owner="$2"; shift 2;; *) shift;; esac; done

enc=$(python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$q")
url="https://skills.sh/api/search?q=${enc}&limit=${limit}"
[ -n "$owner" ] && url="${url}&owner=${owner}"
api_json=$(curl -fsS --max-time 20 "$url" 2>/dev/null || echo '')

gh_json=""
if command -v gh >/dev/null 2>&1; then
  gh_json=$(gh search repos "$q" --topic agent-skills --sort stars --limit "$limit" --json fullName,stargazersCount,url,updatedAt,description 2>/dev/null || echo '')
  [ -n "$gh_json" ] || gh_json=$(gh search repos "$q skill" --sort stars --limit "$limit" --json fullName,stargazersCount,url,updatedAt,description 2>/dev/null || echo '')
fi

python3 -I - "$api_json" "$gh_json" "$q" <<'PY'
import json, sys
api, gh, q = sys.argv[1:4]
rows = {}
try:
    d = json.loads(api) if api else {}
    items = d.get("skills") if isinstance(d, dict) else d
    for it in items or []:
        source = it.get("source") or it.get("repo") or ""
        name = it.get("skillId") or it.get("name") or ""
        key = f"{source}@{name}".lower()
        rows[key] = {"source": source, "name": name, "installs": int(it.get("installs") or 0), "stars": 0,
                     "skills_sh": f"https://skills.sh/{it.get('id') or (source + '/' + name)}",
                     "github": f"https://github.com/{source}" if source else "", "via": "skills.sh"}
except Exception as e:  # noqa: BLE001
    print(f"skills.sh parse failed: {e}", file=sys.stderr)
try:
    for r in json.loads(gh) if gh else []:
        source = r.get("fullName", "")
        key = f"{source}@".lower()
        if any(k.startswith(source.lower() + "@") for k in rows):
            for k, v in rows.items():
                if k.startswith(source.lower() + "@"):
                    v["stars"] = r.get("stargazersCount", 0)
            continue
        rows[key] = {"source": source, "name": "", "installs": 0, "stars": r.get("stargazersCount", 0),
                     "skills_sh": f"https://skills.sh/{source}", "github": r.get("url", ""),
                     "description": (r.get("description") or "")[:140], "updated": (r.get("updatedAt") or "")[:10], "via": "github"}
except Exception as e:  # noqa: BLE001
    print(f"gh parse failed: {e}", file=sys.stderr)
out = sorted(rows.values(), key=lambda r: (-r["installs"], -r["stars"], r["source"]))
print(json.dumps(out, indent=2))
sys.exit(0 if out else 3)
PY
