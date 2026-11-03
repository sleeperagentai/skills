# Planning multi-phase OpenStudio work

SKILL.md already carries the "ADR→config→infra→library→persistence→API→integration→polish, one commit per phase" invariant and the "verify cited paths exist on the base branch" rule for subagent dispatch. This file is for pre-plan checks that go BEFORE either applies — the questions you have to answer before `docs/plans/<date>-<slug>.md` is worth writing.

## Pre-plan branch check (do this before writing phase 1)

`git status` and `git log --oneline main..HEAD` on the current branch BEFORE writing the plan. Three shapes come up on long-lived `feat/*` branches and each needs a different base-branch answer from the user before Phase 1 starts.

1. **Clean tree, branch == main or close to it.** Branch off main for the new feature. No question needed.

2. **Clean tree, branch is a feature branch with unmerged commits unrelated to the new work.** Ask: branch off this feature branch (and stack) OR off main (and let the two features merge later)? Default to main unless the new feature structurally depends on the open one. Before offering to "open a PR for the stray branch", check it was not already squash-merged: `gh pr list --state merged --head <branch>` or look for the same commit title in `git log --oneline main -5`. Squash merges leave the branch tip outside main's ancestry, so `git branch --contains` and `merge-base --is-ancestor` both say "unmerged" and `gh pr create` then fails with "No commits between main and <branch>".

**When one task was deliberately split into sequential PRs (PR 1 then PR 2 covering different halves of the same user ask), PR N+1 branches off main AFTER PR N merges — never off PR N's still-open feature branch.** Starting PR 2 off PR 1's open branch bleeds PR 1's diff into PR 2's review (reviewer sees two features at once), forces a rebase every time PR 1 iterates on reviewer feedback, and poisons PR 2's base if PR 1 is substantially rewritten or reverted. Order when the user signals "ship them sequentially": finish PR 1 → push → open → merge (`gh pr merge --admin --squash --delete-branch` when the user explicitly says to skip checks) → `git checkout main && git fetch origin main && git merge --ff-only origin/main` → `git checkout -b <pr2-branch>`. If a stale PR 2 branch was already cut off PR 1, delete it and recreate off updated main; a worktree-pinned current branch needs `git checkout main` BEFORE `git branch -D <pr2-branch>` or git refuses with "used by worktree". Scope-splitting mid-PR 2 ("PR 2a + 2b") is a conversation to have with the user BEFORE writing code — do not unilaterally carve a planned PR 2 into sub-PRs; propose the split and wait.

## Answering "what's missing / what's done" (feature inventory)

Do not guess from the kind registry. Read, in this order: `docs/BUILD-STATUS.md` (milestones + W-packages), `docs/PRODUCTION-READINESS.md` (numbered launch gates, ordered by blast radius), `docs/GAPS.md` + `docs/CAST-GAPS.md` (product gaps, provider slots still `fake`), the latest `docs/adr/*` Non-goals sections, then the live surfaces: the `FORMATS` array in `apps/web/app/(app)/create/page.tsx` (which formats are still "Coming soon" despite a working render path) and the `aigw:` boot lines in the API log (`ImageGen=fake` means every image-generating surface is placeholder bytes). A kind existing in Go does not mean a user can reach it — report backend vs UI status separately.

## Parallel subagents on one feature

Give each child a DISJOINT write set and name the one file that is the contract between them (exported names + signatures, pasted into both contexts). Only the owner creates that file; the consumer imports it and, if it needs to typecheck before the owner lands, writes a stub at a path it will never commit — never at the real path, because the owner's file replaces it on disk mid-session and the consumer's "my files typecheck" claim then silently depends on whichever version was present. Each child commits only its own paths (`git add <explicit list>`), fixes its own `tsc` errors before committing, and the orchestrator runs `pnpm typecheck && pnpm test` on the merged tree before trusting either summary.

3. **DIRTY tree — the feature the user wants to extend is sitting as untracked / uncommitted files on the current branch mixed in with UNRELATED edits.** Common on long-lived `feat/*` branches that absorbed a side-quest. Do NOT silently stack phases on the dirty tree — the eventual review becomes unreadable because reviewers see one branch carrying two features. Surface the choice to the user explicitly and wait for an answer:
   - A) Commit the baseline on the current branch as one `feat(<x>): baseline from <ADR>` commit and stack new phases on top. Fast; base keeps moving if the current branch keeps absorbing other work.
   - B) Land the current branch to main first (close its PR), then branch cleanly off main. Clean; blocks on the current PR landing.
   - C) Carve the feature-only files to a new `feat/<feature>-core` branch off main as its own PR, then branch the extension off that. Most honest; splits one messy PR into two reviewable ones.

   Also ask about live-spend pre-authorisation for the verification phase in the same clarify call if the plan involves paid providers (ElevenLabs, Higgsfield, OpenAI/Anthropic non-fake) — batching avoids a second round-trip at the end.

## Plan files are local-only — never `git add` them

Plans live at `.hermes/plans/<date>-<slug>.md` inside the repo working tree but the `.hermes/` directory is untracked and must stay that way. When committing per-phase deliverables, stage the explicit code/doc paths — do not `git add .` or `git add -A` from the repo root, which sweeps `.hermes/plans/<file>.md` into the commit. If you edit the plan's STATUS table mid-phase (marking a task shipped), that edit is for your next session, not for review; after staging, `git status` must show the plan file still under "Untracked files" before you commit. If it slipped into the index, `git restore --staged .hermes/plans/<file>.md` and re-check.

## Pre-plan code-reality check

Before writing Phase 2+, grep the actual migration/pricing/adapter files for what already exists. The feature the user describes may be half-built already (a kind registered without a pricing line, a migration added without a store method, an endpoint wired without a UI). The plan has to say "extend X, do not re-create X" or Phase 1 trips over the existing scaffolding. Minimum sweep:

```bash
grep -rn "<feature-noun>" services/pricing/ services/db/migrations/ services/db/store/ apps/api/ apps/web/lib/ apps/web/app/
ls services/db/migrations/ | tail -5    # next free number
```

## Reviewing a proposed motion-graphics pipeline rewrite

Briefs for a "motion-graphics engine" (scene-graph DSL, design spec, storyboard → scenes → QA → render) keep coming back. They tend to call things "assumed present" or "decided" that are not true in this repo.

**Step 0 — get the reference's content before offering any option.** When the ask is "build it on par with <link>", the link is the spec. A `claude.ai/artifact/...` link is not fetchable from here (404 or a bot wall), and the user usually already has it exported as HTML in the repo (`ls docs/*.html`) — look there, then ask for the path; never run a clarify on architecture first. A choice the user makes before you have read the reference gets reversed after you read it, and the reversal costs a full options round.

**Step 0b — map the reference's vocabulary onto the repo before classifying the ask.** `DesignSpec`, `Beat[]`, `wordToFrame`, `BuildManifest`, `/measure + limits.json`, approval frame, signed manifest, contact-sheet vision QA = the scene-graph engine (ADR 0018, `services/motion` + `packages/motion-engine`). "No fixed element kits — the LLM decides the UI per story and theme" on top of that vocabulary is a **scenes-stage swap** (per-beat sandboxed codegen in place of kit filling), not a provider swap to the director agent. Before offering "delete the engine", table what each side owns — word clock (`transcript`), storyboard, DesignSpec + contrast, stage cache + per-beat regen, LLM provider (pricing, retry classes, recording), measured captions, manifest checks + workflow on the engine side; sandbox gate, AST source check, bundle + stills loop on the director side — so the user sees that deleting the engine means rebuilding its column inside the director.

**Ruled direction for the engine: see `references/motion-engine.md` § Codegen series.** Those are user decisions recorded in ADR 0019 (no kit, per-beat codegen with N bespoke real-visual components, assets in v1, Opus for design / Sonnet for code, director deleted). Plan from them; do not re-offer the alternatives.

**Step 0c — when the user says "build", clear every open decision in ONE clarify call before branching.** Each row of the plan's open-decisions table, recommended option first; then rewrite the table as decisions in the plan. Open decisions left in a plan at branch time get guessed by subagents and surface as rip-ups in the schema or deletion tasks.

Then map the live path in one sweep:

```bash
grep -n -A4 'KindProviders' services/visuals/routing.go          # which provider motion-graphics uses
grep -n 'func runDirector' -A30 apps/worker-core/director.go      # how the workflow dispatches it
sed -n 1,60p apps/worker-render/motion-renderer/src/director/types.ts   # Go↔TS wire shape
grep -rln -i 'loudnorm\|LUFS\|duck\|sfx\|with-timestamps' services apps packages --include=*.go --include=*.ts --include=*.tsx
grep -rln '@remotion/player' apps/web --include=*.tsx
grep -n zod packages/schemas/package.json apps/worker-render/motion-renderer/package.json
```

Then check the brief against each item below; each has been wrong in a real proposal before.

1. **Word alignment is not a solved input.** Narration is TTS per turn, then whisper.cpp timings relative to each turn. Turns are stitched onto one absolute timeline only inside the director workspace (`absoluteWords`). ASR text is not script text: numerals, currency and contractions come back spelled differently. Word-index triggers, and any rule like "numbers must come from the beat's words", therefore need a step that matches script tokens to ASR tokens, planned as a first-milestone task.
2. **"Downstream render stage takes a BuildManifest" usually does not exist.** The render activity takes the composition's own render-input type, so say the plan builds the new stage.
3. **Go↔Node hand-offs are Temporal activities on the `render` queue that pass S3 keys, not HTTP calls.** A proposed `POST /render` or `POST /still` loses heartbeats, bounded retries and cancellation on a call that runs for minutes. Recommend activities, with the manifest passed by object key.
4. **One JSON Schema cannot go to Claude verbatim.** Strict structured outputs reject validation keywords and large unions (references/anthropic-adapter-quirks.md). Plan a stripped, narrowed schema for the LLM plus full validation of the response afterwards. Check whether the Go Anthropic adapter supports tool use or structured output yet. Generate Zod 4, because Remotion's `zod/mini` imports need it, even if `packages/schemas` is still on Zod 3. Go code generators handle discriminated unions badly, so budget hand-written decoding.
5. **A human-approval pause conflicts with credit reservations.** `ledger.ReservationTTL` expires held reservations, so a build left waiting overnight for approval loses its hold. Either reserve in two steps (the approval frame, then the full build once approved) or add a paused-reservation state.
6. **The brief must say what happens to the current default provider.** The non-technical-UI rule forbids letting users pick an engine, so a new provider either replaces the default once its done-criteria pass, or stays internal. Each new provider name needs its `services/pricing` line, and each paid asset vendor needs a per-asset price.
7. **Map the brief's style library onto the existing Look picker** (template groups seeded in migrations), or state that the picker is replaced.
8. **"Local parity" models must fit the dev hardware.** Check the VRAM/CUDA requirements of any proposed local model; GPU-only SVG and vision generators need about 16 GB of VRAM. If it doesn't fit, name a fallback that runs on CPU (e.g. LLM-authored SVG behind a sanitiser).
9. **Done-criteria that can never pass:**
   - "byte-identical" checked against an MP4 (H.264 is lossy; see references/motion-graphics-composition.md § Determinism tests);
   - a text-limits generator described as a plain script, when `measureText` needs headless Chrome with the fonts loaded and the limits must be keyed by font and type scale;
   - a milestone that uses an adapter a later milestone builds.
10. **Build time vs the current path.** Put the brief's wall-clock estimate next to the current provider's measured time and cost so the user sees the trade-off.

Answer shape: current-vs-proposed table → repo mismatches → internal faults → decisions (recommended option first). No code until the user says build (standing invariant in SKILL.md).

## When the ask collides with an ADR non-goal or a hard invariant

Read the governing ADR's Non-goals and the code's own stated invariants (e.g. a prompt builder that says "every word that varies comes from the allow-list") before proposing. If the feature bumps one — user uploads where the ADR says "no upload-your-own-face in v1", free text where the builder says allow-list only, "no kit" where the ADR says "fixed vocabulary" — it is a product decision, not UI work: put it in ONE clarify call with the other decisions (asset sourcing, delivery shape), with the recommended option first, and make the plan's first phase an ADR addendum (`## N. <feature> (added <month>)`) that records the override and its guard (consent flag, moderation gate). Do not quietly relax the invariant in code and mention it in a commit message.

When the reversal is architectural (it changes a numbered Decision of an ADR), write a NEW ADR that names what it supersedes, which decisions of the old ADR still stand, and which control replaces the one it removes; set the old ADR's status to `Superseded by ADR NNNN` with a two-line pointer under its title, and add an `## Addendum — Reversal of Decision N` section at the end of a partially reversed ADR. A status line change alone leaves the old rationale reading as current.

**When the user moves a later phase into v1 ("this MUST be in v1"), do not just relabel the phase.** Fold it into the current phase's done-when, add its tasks to that phase's table, re-scope the later phase to what genuinely remains, and update the cost/time row and the risks table in the same edit — then say what changed in one list. A plan whose phase order moved but whose done-when and estimates did not is the kind of drift reviewers catch late.

For "make the UX amazing" asks on a chooser/builder, the user's standing answers are: visuals over text (swatches + tiles), a live plain-English summary, an escape hatch per group (text first, picture second, phased as separate PRs), hand-made/stock art first with generated art as a later pre-authorised spend. Propose that shape; ask only about the parts that spend money or override an ADR.

## Pause before adding a second safety net when the first already covers the realistic case

When the ask is a complementary mechanism ("add account recovery" after 2FA recovery codes shipped; "add SMS fallback" after email OTP; "add a backup payment method" after one is on file), stop one step before scoping and ask whether the primary mechanism already covers the common failure. 2FA recovery codes already handle the realistic "lost my authenticator, still have my inbox" case; the rarer "lost the inbox itself" case has a working manual-SQL runbook. The second mechanism is often 1000+ lines of code, two new tables, a new audit taxonomy and an ops queue — for a case that hits a handful of times per quarter. Rule: before committing to build, enumerate the specific failure modes the primary covers vs. the ones that still require the new mechanism; count the latter at realistic volume. If it's a handful per quarter and a manual runbook exists, name that cost-benefit back to the user explicitly and let them pick deferral WITH their eyes open — do not silently build. The user who asked you to continue the sweep will often happily defer the item once the trade is on the table.

## Take the user's feature description literally — separate what AI WRITES from what AI PICKS

When a creator asks for a visible-text feature ("captions", "titles", "lower-thirds", "subtitles", "chapter markers"), the text content is usually verbatim — the transcript, the user's typed string, a filename — not AI-authored creativity. Before writing a PRD, split the ask into two columns: (a) what pixels say — almost always deterministic/verbatim/user-supplied; (b) what gets chosen about those pixels — position, color, timing, cadence, animation — where an LLM/VLM/heuristic may contribute. Column (a) is the hard contract; column (b) is where auto-vs-manual knobs live. Mixing them ("the AI writes reactive 2-3 word punchlines matched to the audio") when the user said "captions" produces a scope rewrite that costs an entire PRD draft. Concrete UX phrases — "2-3 words on screen", "burned-in", "open caption", "what the person said" — are literal: 2-3 words = rolling transcript window, not AI haikus; burned-in / open = rendered into pixels, no `.vtt` sidecar; "what the person said" = Whisper output byte-for-byte, no paraphrase.

In the uploaded-video + captions territory specifically: `apps/worker-core/activities/whisper.go` (`WhisperTimingsActivity`) and `packages/compositions/src/primitives/Captions.tsx` (four looks, rolling word window, active-word highlight) already ship. A captioning PRD extends those and adds an `ExtractAudioActivity` + a composition that wraps `<OffthreadVideo>` + the existing `<Captions>` — it does not invent a new reactive primitive or a new caption schema with `intent`/`reaction` fields. External-upload shape mirrors `apps/api/external_audio.go` (ffprobe-gate then store, ASR on ingest).

## Pre-plan design-system check

For UI phases, open `apps/web/components/ui/riso/` and the sibling non-riso `apps/web/components/ui/` BEFORE describing new components in the plan. The riso set already has `Dialog`, `Sheet` (bottom), `Drawer` (right 440px), `DropdownMenu`, `Tabs`, `Disclosure`, `Select`, `Switch`, `Toast`. A plan that proposes "a new slide-in panel component" when `Drawer` exists wastes a phase. Name the exact component (e.g. `components/ui/riso/overlays.tsx::Drawer`) in the plan so the implementer doesn't rebuild it.
