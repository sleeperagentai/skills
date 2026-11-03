# Waiting for the merge

`wait-for-merge.sh <pr>` polls `gh pr view` every 5 minutes for up to 60 minutes. The deadline is
written to `state/pr-<n>.deadline` on the first call, so several shorter calls share one hour.

## Per harness

- **Claude Code**: shell calls in the foreground are capped at 10 minutes. Run the script with the
  Bash tool's `run_in_background` option; you are notified when it exits. If the user says the PR
  is merged before then, run `wait-for-merge.sh <pr> --once` (exit 0 confirms) and proceed; the
  background job will exit on its own at the next poll.
- **Codex, Cursor, Gemini CLI, OpenCode, Hermes, others without background shells**: run
  `wait-for-merge.sh <pr> --chunk 540`. Exit 5 means the chunk ended and the PR is still open:
  print one progress line ("still open, 25 of 60 minutes") and call again. Between chunks the user
  can interject.
- **Any harness**: never busy-loop yourself; the script sleeps. Never shorten `--interval` below
  60 seconds against GitHub's API.

## Exit codes

| Code | State | Response |
|---|---|---|
| 0 | `MERGED pr=<n> sha=<sha> name=<name>` | install from main, report path |
| 2 | closed without merge | explain, offer alternatives |
| 3 | timeout; script printed the fallback commands | print them verbatim, stop |
| 4 | gh failed 3 times | check `gh auth status` and network, retry |
| 5 | chunk elapsed or `--once` and still open | progress line, call again (or stop if `--once`) |
| 130 | interrupted | deadline kept; resume later |

## Lost sessions

`pending.sh --list` shows every PR opened by skill-finder with its live state. Step 0 of the
skill runs it so a new session can resume: `MERGED` → install; `OPEN` → offer to wait again;
`CLOSED` → `pending.sh --forget <n>`.
