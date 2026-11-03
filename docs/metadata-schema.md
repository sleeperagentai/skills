# `metadata.json` (per skill)

Lives next to `SKILL.md`. The skills CLI skips a file with this exact name when installing, so it
never reaches an agent; it exists for provenance and for `catalog.json`.

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | int | Always `1`. |
| `name` | string | Must equal the folder name and the frontmatter `name`. |
| `category` | string | Must equal the parent folder and a key in `categories.json`. |
| `description` | string | Short summary (defaults to frontmatter description in the catalog). |
| `license` | string | SPDX id or free text. Empty when upstream has none; then set `license_note`. |
| `license_note` | string | Why the license is missing or unusual. |
| `vendored` | bool | `true` when the skill content is stored in this repo. |
| `modified` | bool | `true` when vendored files differ from upstream; explain in `modification_note`. |
| `modification_note` | string | What was changed and why. |
| `added` / `updated` | date | ISO dates. |
| `tags` | string[] | Search keywords for `skill-finder`. |
| `aliases` | string[] | Other names people use for this skill (search only). |
| `triggers` | string[] | Phrases that should surface this skill (search only). |
| `source` | object | Provenance, see below. |
| `install` | object | `project`, `global`, optional `upstream`: exact commands. |

## `source`

| Field | Meaning |
|---|---|
| `type` | `github` (vendored from a GitHub repo), `local` (authored on this machine or author unknown), `third-party` (installed through a hub, upstream repo not recorded). |
| `repo` | `owner/repo` for GitHub sources. |
| `path` | Path to the skill folder inside the upstream repo (`""` when the repo root is the skill). |
| `commit` / `ref` | Commit SHA (or folder hash from a skills lock file) the copy was taken from. |
| `url` | Link to the folder at that commit. |
| `installed_via` | How it originally got onto the user's machine (skills CLI, Hermes hub, plugin, re-fetched). |
| `origin` | Where it was found locally when this repo was assembled. |
| `author` / `note` | Free text when provenance is partial. |

Template: `docs/metadata.template.json`.
