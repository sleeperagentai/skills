# Agents, scope and auth

## Scope inference (`install.sh`)

| Signal | Scope |
|---|---|
| user says "here", "this project", "this repo" | project |
| user says "globally", "everywhere", "all projects" | global |
| cwd is inside a git repo with `.claude/`, `.agents/`, `.cursor/`, `.codex/`, `.gemini/`, `.opencode/`, `.hermes/` | project |
| anything else | global, and say so |

Ask when the inference is weak and the user did not say.

## Agent inference

The skills CLI detects installed agents by itself. `install.sh` additionally reads the environment
to pass `-a <agent>` for the agent that is running the session:

| Env var | skills CLI agent id |
|---|---|
| `CLAUDECODE` | `claude-code` |
| `CURSOR_AGENT` | `cursor` |
| `CODEX_*` | `codex` |
| `GEMINI_CLI` | `gemini-cli` |
| `OPENCODE` | `opencode` |
| `HERMES_HOME` / `HERMES_AGENT` | `hermes-agent` |

Pass `--agent <id>` (repeatable) to override, or `--agent '*'` through the CLI directly for all.

## Install paths

| Agent | Project | Global |
|---|---|---|
| Claude Code | `.claude/skills/<name>` | `~/.claude/skills/<name>` |
| Codex | `.codex/skills/<name>` | `~/.codex/skills/<name>` |
| Cursor | `.cursor/skills/<name>` | `~/.cursor/skills/<name>` |
| OpenCode | `.opencode/skills/<name>` | `~/.config/opencode/skills/<name>` |
| Gemini CLI | `.gemini/skills/<name>` | `~/.gemini/skills/<name>` |
| Hermes | `.hermes/skills/<name>` | `~/.hermes/skills/<name>` |
| universal (Amp, Antigravity, ...) | `.agents/skills/<name>` | `~/.agents/skills/<name>` |

The CLI symlinks agent folders to one canonical copy under `.agents/skills`; `--copy` makes
independent copies.

## Private repo auth

The CLI tries, in order: git credentials for `https://github.com/sleeperagentai/skills`, then
`gh repo clone`, then SSH `git@github.com:sleeperagentai/skills.git`. If every install fails with a
403/404/"not found":

1. `gh auth status`; if logged out, `gh auth login` on the account that can read the repo.
2. Or `ssh -T git@github.com` should greet the right account; add the key with `ssh-add`.
3. Or set `GH_TOKEN` to a token with `repo` read scope for the CLI's API lookups.

`ensure-cache.sh` uses the same three routes for the catalog clone.
