# Project as the creation root

Every script, audio file, render and quality score belongs to a
`content.projects` row. This is enforced in three places, and all three are
load-bearing.

## Why it was done

The wizard used to create the project at the FINAL "Make video" click.
Abandoning the flow left a billed script and stored audio owned by nothing:
unreachable, unlistable, uncleanable, and project count understated real
pipeline usage. Migration 00025 + the stage guard + step-1 creation make an
orphan structurally impossible rather than merely discouraged.

## Schema (migration 00025)

Six child tables require a project: `scripts` (had no column at all),
`external_audio`, `assets`, `quality_scores`, plus `renders` and `captions`
which already did.

**`external_audio` was MANUFACTURING orphans**, not just permitting them:
its FK was `ON DELETE SET NULL`, so deleting a project silently orphaned
its audio instead of removing it. Check `confdeltype` on every child before
assuming CASCADE.

**Read the live FK graph before writing a cleanup migration.** Two drafts
failed on assumptions:

```sql
SELECT conrelid::regclass::text, confrelid::regclass::text, conname,
       CASE confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'a' THEN 'NO ACTION'
            WHEN 'n' THEN 'SET NULL' WHEN 'r' THEN 'RESTRICT' END
FROM pg_constraint WHERE contype='f' AND connamespace='content'::regnamespace
ORDER BY 2,1;
```

- `content.quality_scores` uses `subject_kind`, NOT `subject_type`.
- `content.renders.output_asset_id -> content.assets` is **NO ACTION**, so a
  bare `DELETE FROM content.assets` aborts. Detach the pointer first.
  `content.series.cover_asset_id` is already SET NULL and needs nothing.

## A new project kind: inputs are assets, outputs are assets, never parallel tables

When designing a new project kind, the temptation is to model the user's
upload as its own surface — `content.videos_external`, `content.uploads_X`,
`content.<kind>_sources` — especially when a sibling ingest handler like
`apps/api/external_audio.go` (ffprobe + private bucket + its own table) seems
to justify the shape. It does not. `external_audio` is the pattern we mirror
for the BYTES-handling discipline (buffered probe, size cap, retention), not
for the schema. The uploaded file is an INPUT to the project the same way a
script is an input: a `content.assets` row with `kind='<something>_source'`
and `project_id` set at creation. The project is created from step 1 (the
upload), with `kind='<new_kind>'` and `settings` carrying the mode choices;
the asset points at the project; every downstream render is another
`content.assets(kind='render_output', project_id=…)` row — identical shape
to every other project kind in the schema.

**The decision test for "should this be its own thing or a project kind" is
mechanical, not philosophical.** List every downstream surface the feature
will eventually touch: boards (`content.board_cards.project_id`), series
(`content.series_episodes.project_id`, `content.series.defaults_json`),
publishing (`content.publications.render_id → content.renders.project_id`),
comments (`content.project_comments.project_id`), checklist, categories.
If any of those apply, the feature is a project kind — because every one of
those surfaces joins through `project_id` and parallel plumbing for a non-
project entity would fork every single one. The cost of forcing a new
project kind through a thin wizard (one step: upload) is far smaller than
the cost of forking boards/series/publishing to accept a second root.

The `external_audio` precedent cuts the other way too: migration 00025
**added** `project_id` to `external_audio` precisely because dangling
outside the project graph was the mistake the repo already corrected.

## API (the half a public key cannot bypass)

`stageGuard` verifies project ownership at **step 4** — after the bounded
body read, BEFORE moderation and generation — so an invalid project costs
no inference and no credits. It lives in the shared guard because flow
strictness is a UI concern and a public API key skips the UI entirely; a
per-handler check means a fifth stage added later silently does not check.

A foreign project returns **NOT_FOUND, never FORBIDDEN** — distinguishing
them confirms which ids exist in other tenants.

Routes that bypass the guard must repeat the check themselves: `POST
/scripts` (legacy async) and `POST /live/audio/external` were both orphan
factories. Grep for handlers that call `CreateScript`/store writes without
`stageGuard` before assuming coverage.

**The guard dereferenced `s.db` unconditionally** and panicked the request
on a server with no database — a panic in the guard makes every stage
unreachable. Found by a no-DB test, not by inspection.

**Tightening the API is only half the change — ship the client in the same
pass.** Making `projectId` required server-side while leaving the wizard's
four stage call sites hand-assembling their own bodies produced a user-facing
"projectId is required. Create a project first." on a page whose URL
contained the id. The client half lives in
`apps/web/app/(app)/create/motion-graphics/stage-request.ts`: every stage body
goes through `stageBody(what, projectId, fields)`, which throws when the id is
absent, and `stage-request.test.ts` structurally asserts no file in that
directory posts to a `/live/` stage endpoint without it. `/live/tts` is
excluded deliberately — an ephemeral voice preview stores nothing. The
general form of this rule (untyped JSON boundaries, the structural test, and
how to scope it) is in the `nextjs-app-router-production` skill.

## Wizard progress and resume

`POST /{kind}/projects/draft` creates the project when step 1 is submitted,
idempotent on a client-supplied `sessionKey` (stored in
`settings->>'wizardSessionKey'`, server-owned — a client PATCH naming it is
ignored, or one session could hijack another's project).

`PATCH /{kind}/projects/{id}/progress` merges wizard state into settings.

**The merge must descend ONE level.** `settings["wizard"]` is itself an
object, so a shallow merge replaced the whole blob and discarded the voices
saved at create — the same bug as `SetProjectSettings` replacing the entire
column, one level deeper. One level only: recursing forever makes it
impossible to CLEAR a nested field (shortening `voiceIds`), because every
absent key reads as "keep".

## Next.js client/server boundary (cost two 500s)

`/projects/{id}/create` is a SERVER page that calls `stateFromSettings()`
during render, so the restored state is in the first paint. Two directive
mistakes broke it — `"use client"` on a pure-function module, and importing
a runtime value out of a `"use client"` module. Both are written up as
general App Router rules in the `nextjs-app-router-production` skill; the
concrete instances here were `resume.ts` / `wizard-flow.ts` (must stay
server-safe) and `initialWizardState` from `wizard-state.tsx` (re-declared
locally as `RESUME_DEFAULTS`, with a test asserting the copies agree).

## Flow rules

Step 1 is `"Start"` (Title + Voices) because the project is created from
the title. Review now owns NO requirements of its own — every one it
reports belongs to an earlier step and can deep-link there.

Resume lands on the **earliest** incomplete step, not the furthest
reachable: the latter skips an earlier gap and leaves a disabled Next whose
explanation is three steps behind the user.

**Never restore `audio.reviewed`.** Hearing the narration gates the
expensive render, and a resumed session has heard nothing in this sitting.
Restore the audio itself so it can be replayed; make them press play.

## Testing notes

**A module-path glob does not run every package — `go test` can report green
on a suite that never executed the broken package.** In this `go.work`
monorepo, `go test github.com/agentclip/openstudio/services/...` resolved
through the workspace and omitted `services/db/store` entirely; seven
fixtures broken by migration 00025's NOT NULL columns survived two
consecutive "full suite green" claims. Before reporting a suite result,
verify the package you changed appears in the output — count the `ok`
lines against the packages you expect, and name packages explicitly
(`go test ./apps/api/ ./services/db/store/`) when a specific one matters.
Treat "the packages I named were green" and "the suite is green" as
different claims.

**Mutation-test a gate in BOTH directions.** For any rule of the form
"refuse X while Y", a predicate that is too EAGER is as broken as one that
is too lax, and only the lax direction is obvious. Confirm that removing
the check fails a test, AND that widening it to cases it must not cover
fails a different one.

**When a store/handler signature gains a required argument, update the
fixtures with TARGETED edits — never a regex sweep over the test files.**
Bulk substitution across `*_test.go` failed three times in a row here, and
each fix created the next failure: two patterns that both matched produced a
duplicate map key; an anchor that assumed a bare line missed a declaration
with a trailing comment, leaving an undefined variable; and a heuristic
papering over that gap put a placeholder id into a DB-backed test, which
then returned 404 instead of the status under test. Only the first two were
caught by `go vet` — the third compiled and lied. Let the COMPILER enumerate
the call sites (`go build ./...` after changing the signature), then fix each
one by reading it. The same lesson applies to `*.test.ts`.

**Fix fixtures at the HELPER, not the call site.** `postStageAudio` had 11
callers; injecting a project there (unless the body names one) kept every
test about its actual subject instead of all failing with "projectId is
required", while letting the cross-tenant tests still supply a bad id.

**A test built with no DB (`newLiveTestState(t, false)`) cannot reach a
guard check that queries the DB.** After `stageGuard` gained the project
lookup, input-validation tests that never previously touched Postgres
started asserting the wrong error. Either give the test a real DB and a
real project, or accept that it now asserts an earlier gate — do not widen
the expected status to make both pass, which is what hides the ordering the
test exists to pin.

**A SKIP reads as PASS on the package summary line.** Cross-tenant tests
first skipped because `content.projects.workspace_id` FKs to
`platform.workspaces` and the foreign workspace id was invented — isolation
looked tested when it was not. Seed the workspace row first.

**A round-trip test cannot prove a reader.** The `reviewed` safety test
passed even with the reader trusting a stored `reviewed:true`, because the
writer never emits that field. Feed the reader a hand-built hostile blob.

## Verifying the flow end to end

`scripts/project-root-e2e.sh` covers the HTTP contract: draft create,
idempotency on a repeated `sessionKey`, 400 with no project, 404 for a
foreign one, settings surviving a later PATCH, and the server-owned session
key. Run it after any change to `stageGuard`, the draft/progress handlers, or
the wizard's stage calls.

Two failure modes of the script itself, both of which cost real debugging
time and both of which generalise to any verification script here:

- **A check that cannot distinguish "rejected" from "wrong answer" invents
  bugs.** Reading a field with `json.load(...).get(key, '')` turned a
  `rate limit exceeded` body into an empty string, which the assertion
  reported as "the server wiped the session key" — a bug that did not exist.
  Assert the status code first, treat an unparseable body as INCONCLUSIVE
  (never as a pass and never as a wrong value), and print the raw head when
  parsing fails. This is the mirror of "a verification script that cannot
  fail manufactures a green signal": one hides real failures, the other
  manufactures fake ones.
- **Scope cleanup globs to the script's own artefact directory.** A broad
  `rm -f /tmp/<prefix>-*` deleted the caller's redirect target, so the run
  finished and its output was gone. Use `ART=/tmp/<script-name>;
  rm -rf "$ART"; mkdir -p "$ART"` and keep every artefact under it.

Also: **re-running the e2e after restarting the API resets the rate limiter**,
which is usually why a previously-passing assertion starts failing on a
hammered endpoint. Confirm against the DB before concluding the handler
changed behaviour.
