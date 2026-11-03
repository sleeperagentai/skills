#!/usr/bin/env bash
# Produce a scorecard for one upstream skill and save its SKILL.md for reading (never executing).
# Usage: vet.sh <owner/repo> <skill-name> [--installs N] [--out DIR]
# Stdout: JSON scorecard. Exit: 0 ok|caution, 2 reject, 3 skill not found in repo.
set -u
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
sf_require gh python3 curl
repo="${1:-}"; name="${2:-}"; [ -n "$repo" ] && [ -n "$name" ] || sf_die "usage: vet.sh <owner/repo> <skill-name> [--installs N] [--out DIR]" 1
shift 2
installs=0; out=""
while [ $# -gt 0 ]; do case "$1" in --installs) installs="$2"; shift 2;; --out) out="$2"; shift 2;; *) shift;; esac; done
sf_mkdirs
[ -n "$out" ] || out="$SF_STATE_DIR/vet/$(echo "$repo-$name" | tr '/' '-')"
rm -rf "$out"; mkdir -p "$out"

meta=$(gh api "repos/$repo" 2>/dev/null) || sf_die "gh api repos/$repo failed (does the repo exist? are you logged in?)" 2
default_branch=$(sf_json_get "$meta" default_branch)
sha=$(gh api "repos/$repo/commits/$default_branch" --jq .sha 2>/dev/null || echo "")
tree=$(gh api "repos/$repo/git/trees/$sha?recursive=1" --jq '.tree[] | select(.type=="blob") | .path' 2>/dev/null || echo "")

# locate the skill folder: <anything>/<name>/SKILL.md, or root SKILL.md whose name matches
path=$(printf '%s\n' "$tree" | grep -E "(^|/)${name}/SKILL\.md$" | grep -vE '^(node_modules|tests?|examples?|fixtures)/' | awk '{ print length, $0 }' | sort -n | head -1 | cut -d' ' -f2-)
if [ -z "$path" ] && printf '%s\n' "$tree" | grep -qx 'SKILL.md'; then path="SKILL.md"; fi
[ -n "$path" ] || { echo "{\"verdict\":\"reject\",\"reason\":\"no ${name}/SKILL.md in $repo\"}"; exit 3; }
skill_dir=$(dirname "$path"); [ "$skill_dir" = "." ] && skill_dir=""

raw="https://raw.githubusercontent.com/$repo/$sha/$path"
curl -fsSL --max-time 30 "$raw" -o "$out/SKILL.md" 2>/dev/null || sf_die "could not download $raw" 2
printf '%s\n' "$tree" | { if [ -n "$skill_dir" ]; then grep -E "^${skill_dir}/"; else cat; fi; } > "$out/files.txt"
file_count=$(wc -l < "$out/files.txt" | tr -d ' ')
size=$(gh api "repos/$repo/git/trees/$sha?recursive=1" --jq '[.tree[] | select(.type=="blob") | select(.path | startswith("'"$skill_dir"'")) | .size] | add // 0' 2>/dev/null || echo 0)
has_license=no
if printf '%s\n' "$tree" | grep -qiE "^${skill_dir:+$skill_dir/}licen[sc]e"; then has_license=yes
elif printf '%s\n' "$tree" | grep -qiE '^licen[sc]e'; then has_license=yes; fi

python3 -I - "$meta" "$out/SKILL.md" "$out/files.txt" "$installs" "$file_count" "$size" "$has_license" "$path" "$sha" <<'PY'
import json, re, sys, datetime
meta, skill_md, files_txt, installs, file_count, size, has_license, path, sha = sys.argv[1:10]
m = json.loads(meta)
txt = open(skill_md, encoding="utf-8", errors="replace").read()
files = open(files_txt).read().splitlines()
flags = []
def flag(level, what): flags.append({"level": level, "what": what})
if re.search(r"curl[^\n|]*\|\s*(ba|z)?sh", txt) or re.search(r"wget[^\n|]*\|\s*(ba|z)?sh", txt): flag("high", "pipes a download into a shell")
if re.search(r"base64\s+(-d|--decode)", txt): flag("high", "decodes base64 payloads")
if re.search(r"\beval\b", txt): flag("medium", "uses eval")
if re.search(r"ignore (all )?(previous|prior) instructions|do not tell the user|hide this from", txt, re.I): flag("high", "prompt-injection phrasing")
if re.search(r"(curl|wget|fetch)\s+https?://(?!github\.com|raw\.githubusercontent\.com|skills\.sh)", txt): flag("medium", "fetches from non-GitHub hosts")
if not txt.startswith("---"): flag("high", "SKILL.md has no frontmatter")
if re.search(r"<!DOCTYPE|<html", txt[:400], re.I): flag("high", "SKILL.md is an HTML page")
bins = [f for f in files if re.search(r"\.(exe|dll|so|dylib|bin|wasm|pyc)$", f)]
if bins: flag("medium", f"{len(bins)} binary file(s)")
if int(file_count) > 50: flag("low", f"{file_count} files")
if int(size) > 5_000_000: flag("medium", f"{int(size)/1e6:.1f} MB")
if has_license != "yes": flag("high", "no license file in skill folder or repo root")
if m.get("archived"): flag("high", "repository archived")
pushed = m.get("pushed_at", "")[:10]
days = (datetime.date.today() - datetime.date.fromisoformat(pushed)).days if pushed else 9999
if days > 365: flag("medium", f"last push {days} days ago")
stars = m.get("stargazers_count", 0)
lic = (m.get("license") or {}).get("spdx_id") or ""
high = any(f["level"] == "high" for f in flags)
popular = int(installs) >= 1000 or stars >= 100
if high: verdict = "reject"
elif popular and not any(f["level"] == "medium" for f in flags): verdict = "ok"
else: verdict = "caution"
print(json.dumps({
    "repo": m.get("full_name"), "stars": stars, "installs": int(installs), "license": lic, "license_file": has_license == "yes",
    "archived": bool(m.get("archived")), "last_push": pushed, "last_push_days": days, "default_branch": m.get("default_branch"),
    "commit": sha, "path": path, "file_count": int(file_count), "bytes": int(size), "description": (m.get("description") or "")[:200],
    "skill_md_saved": skill_md, "flags": flags, "verdict": verdict,
}, indent=2))
sys.exit(2 if verdict == "reject" else 0)
PY
