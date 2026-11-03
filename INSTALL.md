# Installing skills from this repo

Everything here is a standard Agent Skill: a folder with a `SKILL.md`. Any agent that reads
`SKILL.md` files can use them. The recommended installer is the open `skills` CLI from Vercel Labs,
which copies or symlinks the skill folder into the right directory for each agent you use.

## Prerequisites

- Node.js 18 or newer (for `npx`)
- Access to the private repo: one of
  - `gh auth login` (GitHub CLI) on the `sleeperagentai` account, or
  - an SSH key registered on that account, or
  - a git credential helper with a token that can read `sleeperagentai/skills`

The CLI tries normal git credentials first, then `gh repo clone`, then SSH.

## Install with the skills CLI

```bash
# one skill, into the current project (./.claude/skills, ./.agents/skills, ... for detected agents)
npx -y skills add sleeperagentai/skills --skill impeccable -y

# one skill, globally (~/.claude/skills, ~/.agents/skills, ...)
npx -y skills add sleeperagentai/skills --skill impeccable -g -y

# several skills at once
npx -y skills add sleeperagentai/skills --skill test-driven-development --skill code-review-and-quality -g -y

# target specific agents only
npx -y skills add sleeperagentai/skills --skill impeccable -g -a claude-code -a codex -y

# list what is installable
npx -y skills add sleeperagentai/skills --list

# explicit SSH source (same result)
npx -y skills add git@github.com:sleeperagentai/skills.git --skill impeccable -g -y

# keep installed skills current
npx -y skills update
```

`-y` skips prompts, `-g` installs for the user instead of the project, `-a` picks agents
(omit it to let the CLI detect installed agents). Drop `-y` to choose interactively.

## Where skills land

| Agent | Project scope | Global scope |
|---|---|---|
| Claude Code | `.claude/skills/<name>` | `~/.claude/skills/<name>` |
| Codex | `.codex/skills/<name>` | `~/.codex/skills/<name>` |
| Cursor | `.cursor/skills/<name>` | `~/.cursor/skills/<name>` |
| OpenCode | `.opencode/skills/<name>` | `~/.config/opencode/skills/<name>` |
| Gemini CLI | `.gemini/skills/<name>` | `~/.gemini/skills/<name>` |
| Hermes | `.hermes/skills/<name>` | `~/.hermes/skills/<name>` |
| Universal (Amp, Antigravity, others) | `.agents/skills/<name>` | `~/.agents/skills/<name>` |

By default the CLI keeps one canonical copy under `.agents/skills` and symlinks the agent
directories to it. Use `--copy` for independent copies.

## Manual install

```bash
git clone --depth 1 git@github.com:sleeperagentai/skills.git /tmp/sa-skills
cp -R /tmp/sa-skills/skills/design/impeccable ~/.claude/skills/impeccable   # or any agent dir above
rm -f ~/.claude/skills/impeccable/metadata.json                              # provenance file, not needed at runtime
```

## Collections and plugins

Entries under `collections/` are large upstream repos we do not vendor; each JSON file has the
exact upstream install command. Entries under `plugins/` are Claude Code plugins: add the
marketplace, then install the plugin, exactly as written in the file's `install` field.

## Updating a vendored skill from upstream

Re-run the copy from the upstream commit you want, keep `metadata.json`, set `source.commit`
to the new commit and `updated` to today, then run `python3 -I scripts/build-catalog.py` and
`bash scripts/validate.sh` before committing.
