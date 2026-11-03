## What

Adds `{{NAME}}` under `skills/{{CATEGORY}}/`, vendored unchanged from upstream. Opened by `skill-finder`.

## Source

- Upstream: https://github.com/{{REPO}}/tree/{{COMMIT}}/{{PATH}}
- License: `{{LICENSE}}` (license file included in the folder)

## Reviewer checklist

- [ ] Skim `skills/{{CATEGORY}}/{{NAME}}/SKILL.md` and any scripts it ships
- [ ] `metadata.json` provenance looks right (repo, commit, license)
- [ ] CI validate job is green (catalog regenerated, name == folder, no HTML)

## After merge

```bash
npx -y skills add {{SF_REPO}} --skill {{NAME}} -g -y
```
