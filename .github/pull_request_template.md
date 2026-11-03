## What

Adds `<name>` under `skills/<category>/`.

## Source

- Upstream: <https://github.com/OWNER/REPO/tree/COMMIT/PATH>
- License: `<SPDX>` (file included in the folder)
- Popularity: `<installs>` installs on skills.sh, `<stars>` GitHub stars, last push `<date>`

## Checklist

- [ ] I read the whole `SKILL.md` and any scripts it ships
- [ ] Files are unchanged from upstream (or `modified: true` with a note in `metadata.json`)
- [ ] `python3 -I scripts/build-catalog.py` and `bash scripts/validate.sh` pass
- [ ] One skill only, branch `add/<name>`

## Install after merge

```bash
npx -y skills add sleeperagentai/skills --skill <name> -g -y
```
