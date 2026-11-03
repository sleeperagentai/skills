# Adding a skill

The fast path is `skill-finder` itself: it vets, vendors, writes `metadata.json`, regenerates the
catalog and opens the PR. This page describes what it does so the same can be done by hand.

## Rules

1. One skill per pull request, on a branch named `add/<skill-name>`.
2. The folder is `skills/<category>/<name>/` where `<category>` is a key in `categories.json` and
   `<name>` equals the `name:` in the skill's frontmatter (lowercase, digits, single hyphens).
3. Vendor upstream files unchanged. If you must change something, set `"modified": true` in
   `metadata.json` and explain in `modification_note`.
4. A license is required for vendored content: keep the skill's own license file, or copy the
   upstream repo's `LICENSE` into the folder. Upstreams without any license may only be added as a
   `collections/` pointer or with `license_note` explaining the gap.
5. No nested `SKILL.md` below `skills/<category>/<name>/`; flatten sub-skills into their own folders.
6. Keep single files under 5 MB and the folder reasonably small; drop demo media.
7. Never commit secrets. The global pre-commit hook runs gitleaks; placeholders like
   `ghp_xxxxxxxx` are fine.
8. Commit messages are plain descriptions. No AI attribution lines or `Co-Authored-By` trailers.

## Steps

```bash
git checkout -b add/<name> origin/main
mkdir -p skills/<category>/<name>
# copy the upstream skill folder contents here, then:
cp docs/metadata.template.json skills/<category>/<name>/metadata.json   # fill every field
python3 -I scripts/build-catalog.py
bash scripts/validate.sh
git add skills/<category>/<name> catalog.json README.md
git commit -m "Add <name> skill (<category>) vendored from <owner>/<repo>@<short-sha>"
git push -u origin add/<name>
gh pr create --fill
```

The PR template asks for the upstream link at the exact commit, license, popularity signals,
and a note that you read the whole `SKILL.md`.

## Adding a collection or plugin pointer

Create `collections/<name>.json` or `plugins/<name>.json` with `name`, `description`, `repo`,
`url`, `license`, `tags`, and an `install` object whose values are exact commands. Run the
catalog build and validation as above.

## Categories

Add a new category only when nothing in `categories.json` fits; add the key with a one-line
description there in the same PR.
