#!/usr/bin/env bash
# Shared helpers for skill-finder scripts. Source it: . "$SKILL_DIR/scripts/common.sh"
# Works with bash 3.2 (macOS default). No GNU-only flags.

SF_REPO="${SKILL_FINDER_REPO:-sleeperagentai/skills}"
SF_REPO_SSH="git@github.com:${SF_REPO}.git"
SF_REPO_HTTPS="https://github.com/${SF_REPO}.git"
SF_BRANCH="${SKILL_FINDER_BRANCH:-main}"
SF_TTL_HOURS="${SKILL_FINDER_TTL_HOURS:-6}"
SF_CACHE="${SKILL_FINDER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/sleeperagentai-skills}"
SF_REPO_DIR="$SF_CACHE/repo"
SF_WORK_DIR="$SF_CACHE/work"
SF_STATE_DIR="$SF_CACHE/state"
SF_SCRATCH_DIR="$SF_CACHE/scratch"

sf_log()  { printf '[skill-finder] %s\n' "$*" >&2; }
sf_warn() { printf '[skill-finder] WARN: %s\n' "$*" >&2; }
sf_die()  { printf '[skill-finder] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

sf_require() {
  # sf_require cmd1 cmd2 ...  -> exits 2 listing missing commands
  local missing="" c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  [ -z "$missing" ] || sf_die "missing required command(s):$missing" 2
}

sf_mkdirs() { mkdir -p "$SF_REPO_DIR" "$SF_WORK_DIR" "$SF_STATE_DIR" "$SF_SCRATCH_DIR" "$SF_STATE_DIR/lock"; }

# Atomic lock via mkdir. Stale after $2 seconds (default 600). Returns 1 if held.
sf_lock() {
  local name="$1" stale="${2:-600}" dir="$SF_STATE_DIR/lock/$1"
  if mkdir "$dir" 2>/dev/null; then echo "$$" > "$dir/pid"; return 0; fi
  local age
  age=$(( $(date +%s) - $(sf_mtime "$dir") ))
  if [ "$age" -gt "$stale" ]; then rm -rf "$dir"; mkdir "$dir" 2>/dev/null && { echo "$$" > "$dir/pid"; return 0; }; fi
  return 1
}
sf_unlock() { rm -rf "$SF_STATE_DIR/lock/$1"; }

sf_mtime() { # portable file mtime (epoch seconds)
  if stat -f %m "$1" >/dev/null 2>&1; then stat -f %m "$1"; else stat -c %Y "$1"; fi
}

sf_now() { date +%s; }
sf_hms() { # seconds -> HH:MM:SS
  local s=$1; printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60));
}

sf_detect_agent() {
  # Echo the skills-CLI agent id for the agent we are running inside, or nothing.
  if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE:-}" ]; then echo claude-code
  elif [ -n "${CURSOR_AGENT:-}" ]; then echo cursor
  elif [ -n "${CODEX_SANDBOX:-}${CODEX_HOME_SET:-}${CODEX_CI:-}" ]; then echo codex
  elif env | grep -q '^CODEX_'; then echo codex
  elif [ -n "${GEMINI_CLI:-}" ]; then echo gemini-cli
  elif [ -n "${OPENCODE:-}" ]; then echo opencode
  elif [ -n "${HERMES_HOME:-}" ] || [ -n "${HERMES_AGENT:-}" ]; then echo hermes-agent
  fi
}

sf_json_get() { # sf_json_get '<json>' key.path  (dot path, stdlib python)
  python3 -I -c '
import json,sys
d=json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d,list) else d.get(k)
    if d is None: break
print("" if d is None else (d if isinstance(d,str) else json.dumps(d)))' "$1" "$2"
}

if [ "${1:-}" = "--check" ]; then
  sf_require git python3 node npx
  command -v gh >/dev/null 2>&1 || sf_warn "gh not found: search/install still work, but vetting and PRs need GitHub CLI (brew install gh; gh auth login)"
  if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then sf_warn "gh is not logged in (gh auth login)"; fi
  echo "ok: git python3 node npx present; cache at $SF_CACHE; repo $SF_REPO"
fi
