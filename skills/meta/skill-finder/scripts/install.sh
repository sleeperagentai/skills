#!/usr/bin/env bash
# Install one or more skills from the skills repo with the skills CLI.
# Usage: install.sh <name> [<name>...] [--global|--project] [--agent a [--agent b]] [--source owner/repo] [--copy]
# Exit: 0 installed, 2 auth/clone failure, 1 other failure.
set -u
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
sf_require npx node
names=""; scope=""; agents=""; source="$SF_REPO"; copy=""
while [ $# -gt 0 ]; do case "$1" in
  --global|-g) scope=global; shift;; --project|-p) scope=project; shift;;
  --agent|-a) agents="$agents -a $2"; shift 2;; --source) source="$2"; shift 2;; --copy) copy="--copy"; shift;;
  -*) shift;; *) names="$names --skill $1"; shift;; esac; done
[ -n "$names" ] || sf_die "usage: install.sh <name> [...] [--global|--project] [--agent X]" 1

if [ -z "$scope" ]; then
  # project if we are inside a git repo that already has an agent directory, else global
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    top=$(git rev-parse --show-toplevel)
    for d in .claude .agents .cursor .codex .gemini .opencode .hermes .github/skills; do
      [ -d "$top/$d" ] && { scope=project; break; }
    done
  fi
  [ -n "$scope" ] || scope=global
  sf_log "scope not given, inferred: $scope"
fi
gflag=""; [ "$scope" = global ] && gflag="-g"
if [ -z "$agents" ]; then
  det=$(sf_detect_agent)
  [ -n "$det" ] && agents="-a $det" && sf_log "running inside $det; installing for it"
fi

set +e
# shellcheck disable=SC2086
out=$(npx -y skills add "$source" $names $gflag $agents $copy -y 2>&1)
rc=$?
set -e
printf '%s\n' "$out"
if [ $rc -ne 0 ]; then
  if printf '%s' "$out" | grep -qiE 'authentication|permission denied|could not read|403|404|not found|repository .* not found'; then
    sf_die "could not read $source. Fix auth with one of: gh auth login; ssh-add your GitHub key; a git credential helper. Then retry." 2
  fi
  sf_die "skills CLI exited $rc" 1
fi
bash "$(cd "$(dirname "$0")" && pwd)/ensure-cache.sh" --refresh --quiet >/dev/null 2>&1 || true
echo "INSTALLED scope=$scope agents=${agents:-auto} skills=$(echo "$names" | sed 's/--skill //g')"
