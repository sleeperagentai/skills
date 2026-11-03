#!/usr/bin/env bash
# Clone or refresh the shallow cache of the skills repo and print where the catalog is.
# Usage: ensure-cache.sh [--refresh] [--quiet] [--print-root]
# Stdout (machine readable): CATALOG=<path> COMMIT=<sha> AGE_MIN=<n> STALE=0|1
# Exit: 0 ok (possibly stale), 2 no cache and clone failed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
sf_require git python3
sf_mkdirs

force=0; quiet=0; print_root=0
for a in "$@"; do case "$a" in --refresh) force=1;; --quiet) quiet=1;; --print-root) print_root=1;; esac; done
[ "$print_root" = 1 ] && { echo "$SF_CACHE"; exit 0; }

clone() {
  rm -rf "$SF_REPO_DIR"
  git clone -q --depth 1 --single-branch -b "$SF_BRANCH" "$SF_REPO_SSH" "$SF_REPO_DIR" 2>/dev/null && return 0
  git clone -q --depth 1 --single-branch -b "$SF_BRANCH" "$SF_REPO_HTTPS" "$SF_REPO_DIR" 2>/dev/null && return 0
  if command -v gh >/dev/null 2>&1; then
    gh repo clone "$SF_REPO" "$SF_REPO_DIR" -- --depth 1 --single-branch -b "$SF_BRANCH" >/dev/null 2>&1 && return 0
  fi
  return 1
}

stale=0
if [ ! -d "$SF_REPO_DIR/.git" ]; then
  [ "$quiet" = 1 ] || sf_log "cloning $SF_REPO into $SF_REPO_DIR"
  clone || sf_die "could not clone $SF_REPO. Authenticate with one of: gh auth login; an SSH key on the GitHub account; a git credential helper. Then retry." 2
else
  marker="$SF_REPO_DIR/.git/FETCH_HEAD"; [ -f "$marker" ] || marker="$SF_REPO_DIR/.git/HEAD"
  age=$(( ( $(sf_now) - $(sf_mtime "$marker") ) / 60 ))
  if [ "$force" = 1 ] || [ "$age" -ge $(( SF_TTL_HOURS * 60 )) ]; then
    if sf_lock refresh 600; then
      if git -C "$SF_REPO_DIR" fetch -q --depth 1 origin "$SF_BRANCH" 2>/dev/null; then
        git -C "$SF_REPO_DIR" reset -q --hard "origin/$SF_BRANCH"
        touch "$SF_REPO_DIR/.git/FETCH_HEAD"
      else
        stale=1; [ "$quiet" = 1 ] || sf_warn "fetch failed, using cached copy (${age}m old)"
      fi
      sf_unlock refresh
    else
      [ "$quiet" = 1 ] || sf_warn "another refresh is running, using current cache"
    fi
  fi
fi

marker="$SF_REPO_DIR/.git/FETCH_HEAD"; [ -f "$marker" ] || marker="$SF_REPO_DIR/.git/HEAD"
age=$(( ( $(sf_now) - $(sf_mtime "$marker") ) / 60 ))
commit=$(git -C "$SF_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
catalog="$SF_REPO_DIR/catalog.json"
if [ ! -f "$catalog" ] && [ -f "$SF_REPO_DIR/scripts/build-catalog.py" ]; then
  python3 -I "$SF_REPO_DIR/scripts/build-catalog.py" --repo "$SF_REPO_DIR" --stdout > "$SF_STATE_DIR/catalog.generated.json" 2>/dev/null && catalog="$SF_STATE_DIR/catalog.generated.json"
fi
[ -f "$catalog" ] || sf_die "no catalog.json in cache; repo may be broken" 2
echo "CATALOG=$catalog COMMIT=$commit AGE_MIN=$age STALE=$stale"
