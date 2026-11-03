# Codebase gaps / blockers review — authoritative source map

When the user asks "review the codebase and state the main gaps / blockers" (or any variant: production-readiness, launch gates, what's left), DO NOT grep the whole tree first. The team keeps the current state in a small set of markdown files that are updated as work lands — read those, THEN confirm with targeted greps for anything the docs claim is shipped. In this repo the docs are usually correct and the greps are a sanity check, not the primary source.

## Canonical files (in order of signal density)

1. `docs/PRODUCTION-READINESS.md` — numbered §0..N list of release blockers, with blast-radius ordering and a per-tier launch decision framework (friends & family / public beta / GA). Treat §0 as the hardest gate on the page; if it's unresolved, every other item is secondary.
2. `docs/BUILD-STATUS.md` — milestone + W-package table of ✅/🟡/⬜/⏸, plus a "what genuinely runs end-to-end today" section. Use this to know what to trust.
3. `docs/GAPS.md` — design-system + known product gaps (Riso build). The lower half ("Known product gaps") overlaps PRODUCTION-READINESS; the upper half is UI/token-level only.
4. `docs/CAST-GAPS.md` — Cast/presenter/voice workstream status, including items that shipped since PRODUCTION-READINESS was last updated. **Cross-check both documents on the same subject — the newer one wins.** Example mode of divergence: watermark painted "done" in CAST-GAPS and "not done" in PRODUCTION-READINESS; audit the compositions before trusting either.
5. `apps/web/GAPS.md` — Riso Phase-3 web-only gaps. Mostly inlined-component rename map + endpoint stubs; useful for web work, noise for backend reviews.

## Procedure

1. `wc -l` the five docs — if one is >200 lines, skim the headings first and read in full only the sections flagged by the user's question.
2. Read 1 and 2 in full. These are small (<200 lines each) and give you the whole picture.
3. Read sections of 3/4/5 that match the user's angle (billing, auth, media, etc).
4. Cross-check inconsistencies between docs with a grep on the actual code before reporting:
   - "watermark done" → `rg 'watermark' packages/compositions/src apps/worker-render` to see if every composition actually paints it.
   - "rate limit shipped on /live/*" → `rg 'ratelimit|RateLimit' apps/api/live_*.go`.
   - "RLS enforced" → `rg 'set_config\|current_workspace\|FORCE ROW' services/db apps/api`. If the greps return only migration SQL and zero Go hits, policies are decorative — see PRODUCTION-READINESS §0.
5. Produce a tiered answer: hard blockers (data loss, security, correctness) → should-haves (ships without them but degrades) → polish. Match the user's own tiering if they named one ("public beta" vs "GA" vs "friends & family").

## Pitfalls

- **Do not re-derive the gap list from greps alone.** The docs encode blast-radius ordering (why RLS is §0, not just "a thing to do"); greps give you items but not priority. A review that lists 40 TODOs instead of 13 blockers in blast-radius order is the wrong answer.
- **Do not treat PRODUCTION-READINESS as frozen.** It is updated by hand and lags behind merged work by days. Any claim that something is "missing" there must survive a grep against the current `main` before you repeat it to the user.
- **The "friends & family / public beta / GA" tiering at the bottom of PRODUCTION-READINESS is the user's own framework.** Mirror it in your answer; do not invent a parallel scheme.
- **If the user asks for a plan from this review, the plan skill applies — write to `.hermes/plans/YYYY-MM-DD_HHMMSS-<slug>.md` INSIDE the repo workspace**, phase-ordered DAG with per-phase exit criteria. Standing invariants (money as integers, no SQL outside `services/db`, non-technical UI, goose numbering) belong in a "Standing invariants" block near the top so each subagent re-reads them.
