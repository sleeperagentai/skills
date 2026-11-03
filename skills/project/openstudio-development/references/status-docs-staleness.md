# Status docs are chronically stale — grep the code first

When the user asks "what's blocking production?", "what's shipped?", or "review the roadmap/plans", the status docs in this repo lag the code by weeks. Trusting them produces false blockers: items marked open have landed; items marked done sometimes haven't been verified end-to-end.

Docs that have lied in-tree:

- `README.md` and `apps/web/README.md`: carried "audio pipeline (TTS + Whisper timings) is stubbed in Phase 4 Task 17" long after `apps/worker-core/main.go` was running `TTSActivity` per turn with bounded concurrency and `WhisperTimingsActivity` for word timings.
- `docs/BUILD-STATUS.md`: top-of-file snapshot date drifts weeks behind main; the milestone table underneath reflects a prior session's state.
- `apps/web/GAPS.md`: carried `GAP(paid-plans)`, `GAP(phase-3-internal-profile-patch)`, `GAP(phase-3-workspace-api)`, `GAP(phase-3-notification-prefs-api)`, `GAP(phase-3-webhooks-api)` long after the endpoints were on disk and the UI was consuming them.
- `docs/PRODUCTION-READINESS.md`: numbered launch gates listed "Nothing exists in `.github/workflows/`" when CI did exist (and was failing on every main push for weeks); listed OpenAPI / audit coverage as needing new work when both were ~90% done. The TRAIL-HEADER at the top is the current-truth, the numbered body is older state — read both.
- `docs/GAPS.md`, `docs/CAST-GAPS.md`: catalogue product gaps but don't age; a gap closed six weeks ago still reads as open.

## Order of trust for any "is X shipped?" question

1. **Grep the implementation path.** For a backend feature: `rg -n '<handler-or-noun>' apps/api/*.go apps/worker-core/*.go apps/scheduler/*.go services/<domain>/`. For a workflow step: look for the activity name in `apps/worker-core/main.go`. For a route: `grep -nE '/api/v1/<path>|r\.(Get|Post|Patch|Delete)' apps/api/main.go`.
2. **Check the migration.** `ls services/db/migrations/ | tail -5` tells you both the next free number AND whether a referenced table landed.
3. **Check the UI call site.** `rg -n 'apiFetch.*<path>|/<path>' apps/web/app apps/web/components apps/web/lib`. A "Coming soon" tombstone in the UI often sits on top of a fully wired backend — the backend caught up without the UI updating.
4. **ONLY THEN read the doc.** If the doc disagrees with code, the code wins.

## The "review production readiness" workflow

The user has asked variants of "review the codebase and tell me what's blocking prod" multiple times. The first pass almost always lands at least one false blocker because the status doc said so. Avoid the embarrassment:

1. Open `docs/PRODUCTION-READINESS.md` for the LIST of candidate blockers, not the status of each.
2. For each listed item, run the three greps above to independently verify current state. Expect 20–40% of "open" items to be done, 10–20% of "done" items to have an un-verified-live step still pending.
3. Explicitly separate "shipped" from "shipped and live-verified". Stripe is the canonical case: PR1–4 code shipped but no evidence anyone ran `stripe listen` against a real test tenant. Report both states to the user; do not conflate "code merged" with "works in production".
4. **In the same PR that reports the audit, patch every stale doc you touched.** Leaving them stale makes the next session — which may be a different agent entirely — repeat the mistake. Minimum: a reality-check header on `BUILD-STATUS.md` + removal of closed `GAP(...)` bullets from `apps/web/GAPS.md` + a dated trail entry on `PRODUCTION-READINESS.md` for each item you moved. Preserve closed gaps in a "Closed since" table rather than deleting them — git-blame readers need the history.

## Specific anti-pattern: UI "Coming soon" over a wired backend

Dashed-border "Coming soon" cards in the Riso design system are the UI's own `GAP(...)` marker and drift the same way. Before reporting any such card as a launch blocker, verify the backend behind it: a `/settings/notifications` tombstone sits over a complete `GET/PATCH /internal/notification-prefs` + CreateNotification path, a "Post it for you" card sits over an end-to-end Zernio publisher, etc. If the backend is live, the fix is replace the tombstone with a nudge toward the real surface (e.g. `/settings/connections`) — not scope a new feature.

## Specific anti-pattern: PRODUCTION-READINESS.md item marked DONE but with no live-mode verification

"PR1–4 shipped" is not the same as "works against the real vendor". Stripe, OAuth providers, webhook signature verification, email bounce handling: each of these has code paths that only exercise correctly against the real external surface. When the doc says DONE for one of these, the next question is "has anyone actually run it live-mode?" — ask the user before claiming the item closed.

## Human-gated verification items: ship the harness, not the verdict

Some readiness items (render-quality eyeballing, legal review, design QA) are explicitly human-gated — no amount of grep closes them. Do NOT force a close by writing automated "checks" that only test that the pipeline runs; the user flagged these as human-eyeball work for a reason. Instead ship a **harness** that automates every step up to the eyeball: enumerate the matrix (template × aspect × quality), kick off each cell via the real API, poll `GET /api/v1/renders/{id}` to terminal, dump a markdown report with presigned playback URLs. Place it under `scripts/motion/` or `scripts/<domain>/`, chmod +x, document the operator contract (boot stack, drop API key at `/tmp/os-key.txt`, run, walk the report). The harness closes the "this takes an hour to set up" barrier that was keeping the human-gated item open; it does not close the gate itself.
