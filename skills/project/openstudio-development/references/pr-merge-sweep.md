# PR merge sweep ("make sure everything is merged to main")

A sweep, not a single PR. Order:

1. `git fetch origin && gh pr list --state open --json number,title,headRefName,mergeable,mergeStateStatus` — also note local feature branches that are not PRs yet (`git branch --no-merged origin/main`).
2. For each `CONFLICTING` PR: `git checkout <branch> && git reset --hard origin/<branch> && git merge origin/main` (merge INTO the branch, never rebase — branches are shared). `package.json` dependency-list conflicts are the union of both sides. Then `pnpm install --frozen-lockfile` from the repo root — a pass is the proof the auto-merged `pnpm-lock.yaml` is consistent; a fail means hand-resolve the lock.
3. Run the touched module's gates (`pnpm typecheck && pnpm test`, plus any `*.spec.ts` not wired into `pnpm test`), `git merge --continue`, push, confirm `gh pr view N --json mergeable,mergeStateStatus` says `MERGEABLE`.
4. Review gate (SKILL.md standing invariant) — one fresh-context reviewer per PR, independent PRs in ONE parallel `delegate_task` batch. Each reviewer context must spell out the multi-tenant threat model (a hostile brief from tenant A must not reach tenant B's scratch dir, worker secrets, shared vendored dirs, or local infra ports) or the review covers only correctness.
5. Fix Critical/Warning → follow-up commit → second reviewer per fix → `gh pr merge --squash` (see the stacked-PR `--delete-branch` pitfall in motion-renderer.md).
6. Finish with `git checkout main && git pull --ff-only`; the user expects local `main` == `origin/main` at the end and says so explicitly.

## Shipping a phase PR on command while review findings are still open

When the user stops the fix tracks and says "create pr and merge", ship honestly rather than finishing the fixes:

1. Park, don't discard, the children's uncommitted fix work: copy every modified/untracked file to `<scratch>/partial-fixes/<track>/` (keep the fails-before test files too), then `git checkout -- <files>` and delete the temp tests so the tree is clean. The next fix branch resumes from the parked copies.
2. Commit the review ledger with counts computed by a script over its rows (fixed / open / accepted / deferred), never by eye, and name the follow-up branch (`feat/<feature>-phase-N-fixes`) in it.
3. The PR body carries the ledger counts and the open blocker in plain words ("the `engine` default must not serve real traffic until B1 lands"). A squash merge with an unstated blocker is how a half-fixed default reaches production.
4. Pre-merge gate = the full verify block plus a detached clean worktree (`git worktree add --detach <scratch> HEAD`) where `go build ./...` per module and `tsc --noEmit` run — it catches files that only exist because the main checkout is gitignored-dirty.
5. `git push`, `gh pr create --body-file`, check `gh pr view N --json mergeable,mergeStateStatus`, then `gh pr merge N --squash --admin --delete-branch` and `git checkout main && git pull --ff-only`.

## Opening a PR — tooling traps

- **`CONFLICTING` right after `gh pr create` when main only gained someone else's docs usually means a foreign worker branched OFF your feature branch and its PR carried your early commits onto main.** Diagnose before rebasing: `git log --oneline --first-parent <base>..origin/main` shows only their PRs, yet `git diff --stat <base>..origin/main` is huge. Find the last of your commits whose tree main already contains — `git diff --stat <sha> origin/main -- . ':!<their docs paths>'` is empty for it — then replay only what follows: `git rebase --onto origin/main <that-sha> <branch>`. A plain `git rebase origin/main` replays every commit and stops on add/add conflicts at the first duplicated file. Prove the rebase moved no owned content (`git diff --stat <pre-rebase-tip> HEAD -- . ':!<their paths>'` must be empty), rerun the suites, `git push --force-with-lease`, and re-check `mergeable`.
- **A rebase/checkout that aborts with "untracked working tree files would be overwritten" is the foreign worker's leftovers colliding with paths main now tracks.** Main's copy is canonical: move the untracked dir to scratch and retry; never delete it (it may be the only copy of their unmerged edits) and never `git add` it.

- **A pushed branch with no PR may already be on main.** Squash merges leave `git branch -r --contains <sha>` showing only the feature branch, so the branch LOOKS unmerged; `gh pr create` then fails with "No commits between main and <branch>". Check `git merge-base --is-ancestor <sha> origin/main` (or `git log origin/main --grep` for the subject) before opening anything.
- **Write the PR body to a file and pass `--body-file`.** The Hermes terminal tool refuses any foreground command containing `&` — a `--body "$(cat <<EOF …)"` heredoc whose prose says "smart & elegant" is rejected as backgrounding. `write_file` the body to scratch, then `gh pr create --body-file <path>`.