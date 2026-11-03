#!/usr/bin/env bash
# Vendor an upstream skill into the skills repo on a branch and open a pull request.
# Usage: vendor.sh --repo <owner/repo> --name <skill> --category <cat> [--path <dir-in-repo>] [--commit <sha>]
#                  [--tags a,b] [--aliases x,y] [--scorecard FILE] [--license SPDX] [--dry-run] [--no-pr]
# Last stdout line on success: PR=<n> URL=<url> BRANCH=add/<name>
# Exit: 0 ok | 1 bad args | 2 license/download problem | 4 validation failed (worktree kept) | 6 branch/PR already exists
set -u
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
sf_require git gh python3 curl tar
repo=""; name=""; cat=""; path=""; commit=""; tags=""; aliases=""; scorecard=""; lic=""; dry=0; nopr=0
while [ $# -gt 0 ]; do case "$1" in
  --repo) repo="$2"; shift 2;; --name) name="$2"; shift 2;; --category) cat="$2"; shift 2;; --path) path="$2"; shift 2;;
  --commit) commit="$2"; shift 2;; --tags) tags="$2"; shift 2;; --aliases) aliases="$2"; shift 2;; --scorecard) scorecard="$2"; shift 2;;
  --license) lic="$2"; shift 2;; --dry-run) dry=1; shift;; --no-pr) nopr=1; shift;; *) sf_die "unknown arg $1" 1;; esac; done
[ -n "$repo" ] && [ -n "$name" ] && [ -n "$cat" ] || sf_die "need --repo, --name and --category" 1
printf '%s' "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' || sf_die "name '$name' must be lowercase alnum with single hyphens" 1
here="$(cd "$(dirname "$0")" && pwd)"

bash "$here/ensure-cache.sh" --refresh --quiet >/dev/null || exit 2
R="$SF_REPO_DIR"
python3 -I -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(open(sys.argv[2])) else 1)' "$cat" "$R/categories.json" \
  || sf_die "category '$cat' is not in categories.json ($(python3 -I -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1]))))' "$R/categories.json"))" 1
if ls -d "$R"/skills/*/"$name" >/dev/null 2>&1; then sf_die "a skill named '$name' already exists in the repo ($(ls -d "$R"/skills/*/"$name")). Use --name ${name}-$(echo "$repo" | cut -d/ -f1 | tr 'A-Z' 'a-z') or install the existing one." 1; fi
branch="add/$name"
if git -C "$R" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  n=$(gh pr list --repo "$SF_REPO" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null)
  echo "EXISTS branch=$branch pr=${n:-none}"; exit 6
fi

# upstream commit and path
if [ -z "$commit" ]; then
  db=$(gh api "repos/$repo" --jq .default_branch 2>/dev/null) || sf_die "gh api repos/$repo failed" 2
  commit=$(gh api "repos/$repo/commits/$db" --jq .sha 2>/dev/null) || sf_die "could not resolve HEAD of $repo" 2
fi
if [ -z "$path" ]; then
  path=$(gh api "repos/$repo/git/trees/$commit?recursive=1" --jq '.tree[] | select(.type=="blob") | .path' 2>/dev/null \
    | grep -E "(^|/)${name}/SKILL\.md$" | grep -vE '^(node_modules|tests?|examples?|fixtures)/' | awk '{ print length, $0 }' | sort -n | head -1 | cut -d' ' -f2- | xargs -I{} dirname {} 2>/dev/null || true)
  [ "$path" = "." ] && path=""
  if [ -z "$path" ]; then
    gh api "repos/$repo/git/trees/$commit?recursive=1" --jq '.tree[] | select(.type=="blob") | .path' 2>/dev/null | grep -qx 'SKILL.md' || sf_die "could not find ${name}/SKILL.md in $repo@${commit:0:8}; pass --path" 2
  fi
fi
sf_log "vendoring $repo@${commit:0:8} path='${path:-<root>}' as skills/$cat/$name"

# download tarball into a fresh untrusted scratch dir
sf_mkdirs
scratch="$SF_SCRATCH_DIR/$(echo "$repo" | tr '/' '-')-${commit:0:8}"; rm -rf "$scratch"; mkdir -p "$scratch"
gh api "repos/$repo/tarball/$commit" > "$scratch/src.tgz" 2>/dev/null || sf_die "tarball download failed" 2
tar -xzf "$scratch/src.tgz" -C "$scratch" || sf_die "tarball extract failed" 2
root=$(find "$scratch" -mindepth 1 -maxdepth 1 -type d | head -1)
src="$root${path:+/$path}"
[ -f "$src/SKILL.md" ] || sf_die "no SKILL.md at $src" 2
head -c 200 "$src/SKILL.md" | grep -qiE '<!DOCTYPE|<html' && sf_die "upstream SKILL.md is an HTML page, not a skill" 2
fm_name=$(sed -n '1,40p' "$src/SKILL.md" | grep -m1 -E '^name:' | sed 's/^name:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//')
if [ -n "$fm_name" ] && [ "$fm_name" != "$name" ]; then
  sf_warn "frontmatter name is '$fm_name', not '$name'; the folder must match the frontmatter, using '$fm_name'"
  name="$fm_name"; branch="add/$name"
  ls -d "$R"/skills/*/"$name" >/dev/null 2>&1 && sf_die "'$name' already exists in the repo" 1
fi

# worktree on a fresh branch from origin/main
wt="$SF_WORK_DIR/$(echo "$branch" | tr '/' '-')"
git -C "$R" worktree remove --force "$wt" >/dev/null 2>&1 || true
git -C "$R" branch -D "$branch" >/dev/null 2>&1 || true
git -C "$R" worktree add -q -B "$branch" "$wt" "origin/$SF_BRANCH" || sf_die "worktree add failed" 1
dst="$wt/skills/$cat/$name"; mkdir -p "$dst"
( cd "$src" && tar -cf - --exclude=metadata.json --exclude=.DS_Store --exclude=node_modules . ) | ( cd "$dst" && tar -xf - )

# license
has_lic=$(ls "$dst" | grep -iE '^licen[sc]e' | head -1)
if [ -z "$has_lic" ]; then
  rl=$(ls "$root" | grep -iE '^licen[sc]e(\.(md|txt))?$' | head -1)
  if [ -n "$rl" ]; then cp "$root/$rl" "$dst/LICENSE"; has_lic=LICENSE; fi
fi
[ -n "$has_lic" ] || sf_die "no license file in the skill folder or repo root; not vendoring. Add a collections/ pointer instead or install from upstream directly." 2
[ -n "$lic" ] || lic=$(gh api "repos/$repo" --jq '.license.spdx_id // ""' 2>/dev/null | sed 's/NOASSERTION/see LICENSE file/')

# metadata.json
python3 -I - "$dst/metadata.json" "$name" "$cat" "$repo" "$path" "$commit" "$lic" "$tags" "$aliases" "$scorecard" "$SF_REPO" "$dst/SKILL.md" <<'PY'
import json, sys, datetime, re
out, name, cat, repo, path, commit, lic, tags, aliases, scorecard, sf_repo, skill_md = sys.argv[1:13]
txt = open(skill_md, encoding="utf-8", errors="replace").read()
m = re.search(r"^description:\s*(.*)$", txt, re.M)
desc = (m.group(1).strip().strip('"').strip("'") if m else "")
if desc in (">", ">-", "|", "|-"):
    desc = " ".join(l.strip() for l in txt.split("\n", 1)[1].split("\n---")[0].split("description:")[1].splitlines()[1:] if l.startswith("  "))
q = {}
if scorecard:
    try:
        s = json.load(open(scorecard)); q = {"upstream_installs": s.get("installs", 0), "upstream_stars": s.get("stars", 0), "vetted_on": datetime.date.today().isoformat(), "verdict": s.get("verdict", "")}
    except Exception: pass
d = {
  "schema_version": 1, "name": name, "category": cat, "description": desc[:300], "license": lic,
  "vendored": True, "modified": False, "added": datetime.date.today().isoformat(), "added_by": "skill-finder",
  "tags": [t for t in tags.split(",") if t], "aliases": [a for a in aliases.split(",") if a], "triggers": [],
  "quality": q,
  "source": {"type": "github", "repo": repo, "path": path, "commit": commit,
             "url": f"https://github.com/{repo}/tree/{commit}/{path}".rstrip("/"), "installed_via": "skill-finder"},
  "install": {"project": f"npx -y skills add {sf_repo} --skill {name} -y", "global": f"npx -y skills add {sf_repo} --skill {name} -g -y",
              "upstream": f"npx -y skills add {repo} --skill {name} -y"},
}
json.dump(d, open(out, "w"), indent=2, sort_keys=True); open(out, "a").write("\n")
PY

# catalog + validation
python3 -I "$wt/scripts/build-catalog.py" --repo "$wt" >/dev/null || { sf_warn "catalog build failed; worktree kept at $wt"; exit 4; }
if ! bash "$wt/scripts/validate.sh" "$wt" >&2; then sf_warn "validation failed; fix in $wt then commit/push manually"; exit 4; fi
git -C "$wt" add -A
if [ "$dry" = 1 ]; then echo "DRY-RUN worktree=$wt"; git -C "$wt" status --short | head -20; git -C "$wt" diff --cached --stat | tail -3; exit 0; fi

msg="$SF_STATE_DIR/commit-$name.txt"
{
  echo "Add $name skill ($cat) vendored from $repo@${commit:0:8}"
  echo
  echo "Source: https://github.com/$repo/tree/$commit/$path"
  echo "License: $lic"
  if [ -n "$scorecard" ] && [ -f "$scorecard" ]; then
    python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print(f"Popularity: {s.get(\"installs\",0)} installs, {s.get(\"stars\",0)} stars, last push {s.get(\"last_push\",\"\")}")' "$scorecard"
  fi
} > "$msg"
git -C "$wt" -c core.editor=true commit -q -F "$msg" || sf_die "commit failed (a git hook may have rejected it; see output above)" 1
git -C "$wt" push -q -u origin "$branch" || sf_die "push failed" 1
[ "$nopr" = 1 ] && { echo "PUSHED branch=$branch (no PR requested)"; exit 0; }

body="$SF_STATE_DIR/pr-body-$name.md"
sed -e "s|{{NAME}}|$name|g" -e "s|{{CATEGORY}}|$cat|g" -e "s|{{REPO}}|$repo|g" -e "s|{{COMMIT}}|$commit|g" -e "s|{{PATH}}|$path|g" -e "s|{{LICENSE}}|$lic|g" -e "s|{{SF_REPO}}|$SF_REPO|g" \
  "$here/../templates/pr-body.md" > "$body"
if [ -n "$scorecard" ] && [ -f "$scorecard" ]; then
  { echo; echo "## Vetting scorecard"; echo; echo '```json'; cat "$scorecard"; echo '```'; } >> "$body"
fi
url=$(gh pr create --repo "$SF_REPO" --base "$SF_BRANCH" --head "$branch" --title "Add $name skill ($cat)" --body-file "$body" 2>&1 | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | head -1)
[ -n "$url" ] || sf_die "gh pr create did not return a PR URL" 1
num=${url##*/}
bash "$here/pending.sh" --add "$num" "$url" "$name" "$branch" >/dev/null
echo "PR=$num URL=$url BRANCH=$branch"
