#!/usr/bin/env bash
# Validate the skills repo. Prints "path: message" for every problem, exits 1 if any.
# Usage: bash scripts/validate.sh [repo-root]
set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2
errors=0
err() { printf '%s\n' "$*" >&2; errors=$((errors + 1)); }

# 1. Every skill: skills/<category>/<name>/SKILL.md
while IFS= read -r skill_md; do
  dir=$(dirname "$skill_md")
  name=$(basename "$dir")
  cat=$(basename "$(dirname "$dir")")
  depth=$(printf '%s' "$skill_md" | awk -F/ '{print NF}')
  [ "$depth" -eq 4 ] || err "$skill_md: must be exactly skills/<category>/<name>/SKILL.md"
  head -1 "$skill_md" | grep -q '^---[[:space:]]*$' || err "$skill_md: line 1 must be '---' (frontmatter)"
  if ! sed -n '2,80p' "$skill_md" | grep -q '^---[[:space:]]*$'; then err "$skill_md: frontmatter not closed within 80 lines"; fi
  fm_name=$(python3 -I scripts/frontmatter.py "$skill_md" 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("name",""))' 2>/dev/null)
  if [ -z "$fm_name" ]; then
    err "$skill_md: frontmatter does not parse or has no name"
  else
    [ "$fm_name" = "$name" ] || err "$skill_md: name '$fm_name' != directory '$name'"
    printf '%s' "$fm_name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || err "$skill_md: name '$fm_name' must be lowercase alnum and single hyphens"
    [ "${#fm_name}" -le 64 ] || err "$skill_md: name longer than 64 chars"
  fi
  desc_len=$(python3 -I scripts/frontmatter.py "$skill_md" 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(len(str(d.get("description",""))))' 2>/dev/null || echo 0)
  [ "${desc_len:-0}" -gt 0 ] || err "$skill_md: description missing"
  [ "${desc_len:-0}" -le 1024 ] || err "$skill_md: description longer than 1024 chars"
  # saved web pages instead of skills
  if head -5 "$skill_md" | grep -qiE '<!DOCTYPE|<html'; then err "$skill_md: looks like an HTML page, not a skill"; fi
  # metadata.json
  meta="$dir/metadata.json"
  if [ -f "$meta" ]; then
    python3 -I - "$meta" "$name" "$cat" <<'PY' || errors=$((errors + 1))
import json, sys
p, name, cat = sys.argv[1:4]
try:
    d = json.load(open(p, encoding="utf-8"))
except Exception as e:  # noqa: BLE001
    print(f"{p}: invalid JSON ({e})", file=sys.stderr); sys.exit(1)
bad = []
if d.get("schema_version") != 1: bad.append("schema_version must be 1")
if d.get("name") != name: bad.append(f"name {d.get('name')!r} != dir {name!r}")
if d.get("category") != cat: bad.append(f"category {d.get('category')!r} != dir {cat!r}")
if d.get("vendored", True) and not isinstance(d.get("source"), dict): bad.append("vendored skill needs a source object")
if bad:
    print(f"{p}: " + "; ".join(bad), file=sys.stderr); sys.exit(1)
PY
  fi
  # category must be known
  python3 -I -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(open("categories.json")) else 1)' "$cat" || err "$skill_md: category '$cat' not in categories.json"
done < <(find skills -name SKILL.md | sort)

# 2. No SKILL.md directly under a category (would shadow the skills below it for the skills CLI)
while IFS= read -r f; do err "$f: SKILL.md directly under a category folder shadows its children"; done < <(find skills -mindepth 2 -maxdepth 2 -name SKILL.md)
# 3. No nested skills deeper than skills/<cat>/<name>
while IFS= read -r f; do err "$f: nested SKILL.md deeper than skills/<category>/<name> is not installable"; done < <(find skills -mindepth 4 -name SKILL.md -not -path '*/node_modules/*')

# 4. Collections and plugins: valid JSON with name == filename, unique names overall
python3 -I - <<'PY' || errors=$((errors + 1))
import json, os, sys
names = {}
bad = 0
for sub in ("collections", "plugins"):
    if not os.path.isdir(sub):
        continue
    for fn in sorted(os.listdir(sub)):
        if not fn.endswith(".json"):
            continue
        p = os.path.join(sub, fn)
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            print(f"{p}: invalid JSON ({e})", file=sys.stderr); bad += 1; continue
        if d.get("name") != fn[:-5]:
            print(f"{p}: name {d.get('name')!r} != filename", file=sys.stderr); bad += 1
        for k in ("description", "repo", "install"):
            if not d.get(k):
                print(f"{p}: missing {k}", file=sys.stderr); bad += 1
        names.setdefault(d.get("name"), []).append(p)
for cat in os.listdir("skills"):
    cd = os.path.join("skills", cat)
    if os.path.isdir(cd):
        for n in os.listdir(cd):
            if os.path.isfile(os.path.join(cd, n, "SKILL.md")):
                names.setdefault(n, []).append(os.path.join(cd, n))
for n, ps in names.items():
    if len(ps) > 1:
        print(f"duplicate name {n!r}: {', '.join(ps)}", file=sys.stderr); bad += 1
sys.exit(1 if bad else 0)
PY

# 5. Oversized files (keep installs fast)
while IFS= read -r f; do err "$f: file larger than 5 MB"; done < <(find skills -type f -size +5M)

# 6. catalog.json up to date
if [ -f catalog.json ]; then
  python3 -I scripts/build-catalog.py --check >/dev/null 2>&1 || err "catalog.json/README.md: out of date, run python3 -I scripts/build-catalog.py"
fi

if [ "$errors" -gt 0 ]; then
  printf '\n%d problem(s) found\n' "$errors" >&2
  exit 1
fi
printf 'validate: OK (%s skills)\n' "$(find skills -name SKILL.md | wc -l | tr -d ' ')"
