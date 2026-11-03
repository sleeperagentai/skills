# PR and commit granularity for planned work

Standing user-stated rule for OpenStudio feature work driven by a plan under `docs/plans/<date>-<slug>.md`:

> **One commit per TASK. One PR per PHASE. Phases merge SERIALLY — Phase N's PR must be on `main` before Phase N+1 branches.**

SKILL.md's older "one commit per phase" bullet is for standalone infra sweeps that have no per-task breakdown. Any plan with explicit `Task 1.1`, `Task 1.2`, … bullets uses this stricter cadence instead.

## Branch naming

- Phase 1: `feat/<feature>`
- Phase N≥2: `feat/<feature>-phase-N-<tag>` (e.g. `feat/captioned-clip-phase-2-worker`)

## Why not stack phase branches

Stacking (branching Phase 2 off Phase 1 before Phase 1 merges) is tempting — it unblocks forward work and lets children keep running. The user has explicitly rejected it. Reasons that justify the rule:

- Reviewer of Phase 2 sees Phase 1's diff bleeding into the base — two features in one review.
- Every iteration on Phase 1 (reviewer-requested fixes) forces a rebase of Phase 2 and every open PR stacked on it.
- If Phase 1 is substantially rewritten or reverted during review, Phase 2's base is poisoned and needs manual recovery.
- A sequential merge gate is the one checkpoint that forces a human to look at the integration state before more work piles on — skipping it to parallelise is how five-phase plans turn into unreviewable mega-branches.

Stack only when the user has explicitly authorised it for a specific plan.

## Why one commit per task

- Bisect lands on the single task that regressed, not a 40-file phase blob.
- Reviewer reads one task's diff at a time; `git log --oneline` reads as the plan's task list, in order.
- Subagent-driven execution stays honest — a child that merges two tasks into one commit is doing more than its brief, and the one-commit discipline makes the drift visible on review.
- The task's commit message becomes the natural handoff artefact for the next task's subagent brief ("base off <sha>").

## Operational checklist for a phase

1. Branch off `main` (Phase 1) or off `main` after prior phase merged (Phase N≥2): `git checkout main && git fetch origin main && git merge --ff-only origin/main && git checkout -b feat/<feature>-phase-N-<tag>`.
2. Commit the plan + any docs changes as the first commit on the branch (`docs(<feature>): plan + PRD for phase N`).
3. Dispatch Task N.1 → verify → one commit. Task N.2 → one commit. Each task's subagent brief MUST say "ONE commit on <branch>" and must stage an explicit file list (never `git add -A`).
4. Final task of each phase is a fresh-context adversarial review (`subagent-driven-development`'s two-stage review model). Fixes land as follow-up commits (one per critical finding), each re-reviewed before the PR opens.
5. Open the PR for this phase. Wait for merge before Task (N+1).1 touches anything.

## Subagent brief boilerplate

Every per-task dispatch for a planned phase should carry these literal lines in the context:

> Branch `feat/<feature>` (or `feat/<feature>-phase-N-<tag>`), already checked out. Phase N of `docs/plans/<date>-<slug>.md`. **ONE commit on this branch**: `<type>(<scope>): <subject>`. Stage ONLY the files you created or modified for THIS task — do NOT `git add -A` or `git commit -am`. Verify with `git show --stat HEAD` before reporting.

## Sweep-commit workflow (not a planned phase)

When the user says "commit all the work that's been done" and `git status` on `main` shows uncommitted follow-on work from a just-landed feature, it is NOT a planned-phase task — but it still must not land on `main` directly. Same branch gate as any feature:

1. `git checkout -b feat/<descriptive-slug>` BEFORE `git add`. Pick a slug that names the follow-on surface (e.g. `feat/<feature>-themes`), not `wip` or `misc`.
2. `git add -A` is acceptable HERE (not in a planned task) because the user asked to commit everything; still eyeball `git status --short` first to catch a stray build artefact.
3. One commit, Conventional-Commits subject + body enumerating the touched surfaces by top-level dir (`apps/api`, `apps/web`, `packages/compositions`, `services/db/store`, `docs`, `openapi`).
4. When the user says "push, open PR, merge, do not wait for CI": `git push -u origin <branch>` → `gh pr create --title ... --body ...` (append `[skip ci]` to the body only when the user asked to skip CI) → `gh pr merge <N> --squash --admin --delete-branch` → `git checkout main && git pull --ff-only`. `--admin` is what bypasses the CI gate; `gh pr merge --auto` is the WRONG one-liner here because it waits.
5. Verify local main caught up with `git log --oneline -3` — the squash commit's `(#N)` suffix must be the newest line.
6. Check the run on `main` (`gh run list --branch main --limit 3`). If every job failed within 2-5 s with zero steps, it is not a code failure. Read the annotations (`gh api repos/agentclip/openstudio/check-runs/<job-id>/annotations`). "Recent account payments have failed or your spending limit needs to be increased" means GitHub billing is refusing jobs: tell the user (Settings → Billing & plans) instead of debugging.

This is a sweep, not a phase: no plan file, no per-task cadence, no adversarial review round. If the follow-on diff grew beyond a single reviewable surface (>200 files or crosses unrelated features), stop and ask whether to split it into phases instead of landing one mega-sweep.

## When the strict rule should bend

- A trivial dependency bump (`go mod tidy` added one line; `pnpm update` churned the lockfile) that another task genuinely needed can ride along with that task — do not open an extra PR for a one-line adjunct. State in the task's report that the adjunct rode along.
- A fix commit landed during adversarial review in the same phase does NOT need to collapse into the originating task's commit — keep it as `fix(<scope>): <what the reviewer caught>` so the review trail is readable.
- Do NOT bend the rule to shrink a task that turned out larger than planned: split the task, update the plan, and keep one commit per (new, smaller) task.
