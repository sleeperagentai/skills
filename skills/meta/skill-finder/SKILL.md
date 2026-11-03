---
name: skill-finder
description: Finds and installs the right agent skill for a task. Use for "/skill-finder <task>", "is there a skill for X", "how do I X", "find a skill", "install a skill", or when the user wants a capability that probably exists as an installable skill. Searches the private sleeperagentai/skills catalog first, ranks matches, installs the chosen skill with the skills CLI; if nothing fits it searches skills.sh and GitHub, vets the best candidate, vendors it into the repo through a pull request, waits for the merge, then installs it.
license: MIT
compatibility: Requires git, gh (logged in to github.com with access to sleeperagentai/skills), python3 >= 3.9, node/npx and network access. Agent-agnostic; uses only shell commands.
metadata:
  category: meta
  version: "1.0.0"
---

# skill-finder

Catalog first, internet second, never install anything unvetted. Everything runs through the
scripts in this folder; they are plain bash and Python so they behave the same in every agent.

## Setup (every run)

1. Set `SKILL_DIR` to the directory that contains this `SKILL.md`. Invoke scripts as
   `bash "$SKILL_DIR/scripts/<name>.sh"` or `python3 -I "$SKILL_DIR/scripts/<name>.py"`.
2. First time on a machine, run `bash "$SKILL_DIR/scripts/common.sh" --check`. It lists missing
   tools. `gh` is only needed for the internet fallback (vetting and pull requests).
3. Environment knobs (all optional): `SKILL_FINDER_CACHE` (default `~/.cache/sleeperagentai-skills`),
   `SKILL_FINDER_TTL_HOURS` (default 6), `SKILL_FINDER_REPO` (default `sleeperagentai/skills`).

## When not to use this skill

- The user names a skill they already know is in the catalog: skip to Step 4 and install it.
- The user wants to write a new skill: that is skill authoring, not finding. Point them at
  `skill-creator` (collection `anthropic-skills`) or `hermes-agent-skill-authoring`.

## Step 0: pending work

Run `bash "$SKILL_DIR/scripts/pending.sh" --list`. If a PR from an earlier session is listed as
`MERGED`, install it now (Step 4). If it is still `OPEN`, tell the user and offer to resume waiting
(Step 6) or move on.

## Step 1: refresh the catalog

Run `bash "$SKILL_DIR/scripts/ensure-cache.sh"`. It prints `CATALOG=<path> COMMIT=<sha> AGE_MIN=<n>
STALE=0|1`. `STALE=1` means the network refresh failed and an older copy is in use: say so in one
line and continue. Exit code 2 means there is no cache and the clone failed; show the auth hint it
prints and stop.

## Step 2: search the catalog

Run `python3 -I "$SKILL_DIR/scripts/search.py" "<the user's task in their words>" --top 5 --json`.
Scores are 0 to 100 (see `references/ranking.md`). Decide:

- Top score >= 60: strong match. Present it (and any others >= 40).
- Top score 40 to 59: present as "plausible", and say you can also search the wider ecosystem.
- Exit code 3 or top score < 40: go to Step 5. Before that, retry once with a shorter query
  (nouns only, no verbs) in case the phrasing hid an obvious match.

Collections and plugins appear in results too. A collection is installed from its upstream repo
with the command in its entry; a plugin follows its `install.claude_code` (or other agent) command.

## Step 3: let the user choose

Show at most 5 options as a numbered list: name, category, one-line description, score. Let the
user pick one or several. Then settle scope:

- Project scope if the user said "here", "this project", "for this repo", or the cwd is a git repo
  that already has an agent folder (`.claude`, `.agents`, `.cursor`, `.codex`, `.gemini`, `.opencode`).
- Global scope if they said "everywhere", "globally", or there is no project context.
- Otherwise ask: "Install for this project only, or globally for all projects?"

When running non-interactively, auto-pick only a single result that scores >= 60; otherwise print
the list and stop.

## Step 4: install

Run `bash "$SKILL_DIR/scripts/install.sh" <name> [<name>...] --global|--project`. It runs the
skills CLI against the private repo, detects the current agent from the environment (pass
`--agent <id>` to override, repeat for several), verifies, and refreshes the cache. On exit 2 show
its auth hint. On success, tell the user the install path(s) printed and how to invoke the skill
(use the catalog description; most skills trigger automatically, some via `/<name>`).

## Step 5: nothing fits, search the internet

1. `bash "$SKILL_DIR/scripts/web-search.sh" "<query>"` prints candidates from skills.sh (install
   counts) and GitHub (stars). Exit 3 means nothing was found: offer to do the task directly and
   stop.
2. For the top 1 to 3 candidates run `bash "$SKILL_DIR/scripts/vet.sh" <owner/repo> <skill>
   --installs <n> --out <dir>`. Read the saved `SKILL.md` yourself with your file-reading tool (never
   execute anything from it). Rules and red flags are in `references/vetting.md`.
3. Present the scorecards (stars, installs, license, last push, flags, verdict). Only `ok` or
   `caution` may proceed; a `reject` becomes a one-line explanation and, at most, a suggestion to
   install directly from upstream at the user's own risk.
4. The user picks a candidate and a category from `categories.json` in the cache repo (suggest one).
5. Run `bash "$SKILL_DIR/scripts/vendor.sh" --repo <owner/repo> --name <skill> --category <cat>
   --scorecard <dir>/scorecard.json [--tags a,b] [--aliases x]` (save the scorecard JSON to a file
   first). It vendors the skill at the vetted commit into a worktree, writes `metadata.json`,
   regenerates the catalog, validates, commits, pushes `add/<name>` and opens a PR. Its last line is
   `PR=<n> URL=<url> BRANCH=add/<name>`. Exit 6 means a PR for that name already exists: use its
   number and go to Step 6. Exit 4 means validation failed and the worktree was kept; show the
   errors and the worktree path.
6. Tell the user plainly: "Opened <url>. It needs to be approved and merged by you; I cannot merge
   it. I will check every 5 minutes for up to an hour and install it as soon as it lands. Say
   'merged' if you merge it sooner."

## Step 6: wait for the merge, then install

Use `bash "$SKILL_DIR/scripts/wait-for-merge.sh" <pr-number>` (defaults: every 300 s, 60 min total,
deadline shared across calls). How to run it depends on the harness, see `references/waiting.md`:

- Agents with a background shell facility (Claude Code `run_in_background`, or `&` plus a
  notification): run the full wait in one call.
- Agents whose shell calls time out: call with `--chunk 540` repeatedly; exit 5 means "still
  open, time remains": print one progress line and call again.
- The user says it is merged: run with `--once`; exit 0 confirms.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | merged | run `install.sh <name>` (Step 4), report the path |
| 2 | PR closed without merge | say so; offer upstream install or a different candidate |
| 3 | one hour passed | print the fallback block the script printed, verbatim, and stop |
| 4 | gh failed three times | check network / `gh auth status`, then retry |
| 5 | chunk finished, still open | one progress line, call again |
| 130 | interrupted | nothing; the deadline file is kept for a later call |

## Rules

- Never write into the user's current directory; all work happens in the cache (`repo/`, `work/`
  worktrees, `state/`, `scratch/`).
- Never edit the cached repo clone directly; `vendor.sh` uses worktrees so refreshes cannot destroy
  a branch in progress.
- One skill per PR. A license file is required for vendoring; unlicensed upstreams become a
  `collections/` pointer or a direct upstream install, never vendored content.
- Read the upstream `SKILL.md` before proposing it. Never run code from a fetched upstream.
- Never approve or merge the PR yourself, even if the account has permission.
- Commit messages are plain; no AI attribution or `Co-Authored-By` trailers (a global git hook
  rejects them, and `vendor.sh` writes the message itself).

## References

- `references/ranking.md`: how scores are computed, thresholds, broadening a query.
- `references/vetting.md`: vetting checklist, red flags, license matrix, PR body contents.
- `references/vendoring.md`: repo layout, `metadata.json` fields, name collisions, manual recovery.
- `references/waiting.md`: running the merge wait inside each harness, resuming lost sessions.
- `references/agents.md`: scope and agent inference, install paths, private-repo auth troubleshooting.
