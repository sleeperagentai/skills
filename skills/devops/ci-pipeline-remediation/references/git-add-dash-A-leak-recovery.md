# Recovering a PR after a `git add -A` leak

`git add -A` stages every untracked file not covered by `.gitignore`. Common leaks:

- **Build output not yet gitignored**: `packages/*/build/`, `dist/`, `.next/cache/`, `storybook-static/`, Remotion `build/` bundles, Go `bin/`, Python `__pycache__/`.
- **Agent / editor scratch**: `.hermes/` (plans, scoping docs), `.cursor/`, `.aider*`, `.claude/`.

Symptom: `git diff --cached --stat | tail -3` shows an insertion count wildly larger than the real change (hundreds of thousands of lines for a few-file edit).

## Pre-commit scan (make this a habit)

After any `git add -A` or `git add .`:

```bash
git diff --cached --stat | tail -3   # inspect totals — 400 files / 300k lines is a smell
git diff --cached --name-only | grep -E '^(\.hermes|\.cursor|dist|build|storybook-static|\.next/cache)/' \
  && echo "LEAK — unstage before commit"
```

If the scan flags anything, unstage before committing:
```bash
git restore --staged .hermes/ .cursor/ packages/*/build/   # name whatever leaked
```

## Recovery when the leak is already in a local commit

```bash
git reset --soft HEAD~1              # keep working-tree changes, drop the commit
echo 'packages/compositions/build/' >> .gitignore   # add every leaked dir to .gitignore
git rm -r --cached packages/compositions/build/     # untrack what was staged (safe for build output)
git restore --staged .hermes/        # drop scratch dirs from the index entirely
git add .gitignore <files you actually changed>
git commit -m "<your real message>"  # re-commit without the artifacts
```

Key distinction:

- **`git rm -r --cached <dir>/`** — use for build output. Removes from the index AND from future commits in the branch, but keeps the local working-tree files intact so your dev loop isn't broken. Build artifacts regenerate on the next build.
- **`git restore --staged <dir>/`** — use for scratch dirs (`.hermes/`). Just unstages; the files stay untracked and locally present.
- **Never `git rm` source directories** without reading the diff carefully — `--cached` keeps the working tree, but `git rm` without `--cached` deletes files on disk.

## Recovery when the leak already landed on `main`

Same flow but on a new chore branch:

```bash
git checkout main && git pull
git checkout -b chore/untrack-build-output
echo 'packages/compositions/build/' >> .gitignore
git rm -r --cached packages/compositions/build/
git add .gitignore
git commit -m 'chore: stop tracking packages/compositions/build (build output)'
git push -u origin HEAD
# open a small PR with the ignore + rm --cached change only
```

Collaborators keep their local build output because `git rm --cached` only affects the index; their next pull removes the files from history-tracking but leaves them on disk.

## Prevention

- Keep `.gitignore` entries for all build output directories a build tool emits, even if you've never seen them yet. Add `**/build/`, `**/dist/`, `**/.next/`, `**/storybook-static/`, `**/.cache/`, `**/node_modules/`, `**/.turbo/` on day 1.
- `.hermes/` belongs in `.gitignore` at the repo root for any repo an agent might touch. It's local-only scratch.
- Prefer explicit `git add <files>` for small changes. `git add -A` is only safe when the scan above returns clean.
