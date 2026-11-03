# The project root, and making a relationship REQUIRED

Three things: the standing product rules for OpenStudio's creation root, the
procedure for turning an optional FK into a required one across DB/Go/tests,
and the project-scoped wizard (draft create, progress save, resume). Read
before adding a stage, a wizard step, or any `NOT NULL` relationship
rollout.

## Product rules (the user specified these; do not relitigate)

- **`content.projects` is the root of every creation.** No script, audio,
  render, asset or quality score may exist without one. `project_id` is
  `NOT NULL ON DELETE CASCADE` on `scripts`, `renders`, `captions`,
  `external_audio`, `assets` and `quality_scores`.
- **A new user-facing creation surface is a `projects.kind`, not a new root table.** When the ask starts "the user uploads/pastes/picks X and we produce a video," the upload is INPUT to a `kind='<new>'` project row, not a parallel entity. `external_audio` is the precedent: it looks like a standalone artefact and still carries `project_id NOT NULL` so renders / boards / series / publishing / categories / comments all keep working through the one `projects.id` join. A parallel `videos_external` / `uploads` / `clips` root table has to re-plumb every one of those surfaces, which is the mistake 00025 was written to prevent. The source bytes are a `content.assets` row with its own `kind='source_<thing>'` and `project_id` set; the project kind is what the UI and the pipeline switch on.
- **Create the project when the user SUBMITS the first wizard step** — not
  when they land on it, and not at the final "Make video" click. Landing on
  step 1 must create nothing, or every abandoned page view becomes a row.
- **Step 1 is Title + Voices.** The title is required at creation, so there
  is no "Untitled project" placeholder to rename later.
- **The project id appears in the URL after step 1**, route shape
  `/projects/{projectId}/create` — project-scoped, wizard nested under it.
  Every subsequent step and service call is scoped to that project.
- **Revisiting that URL RESUMES the wizard** from saved state and jumps to
  the first incomplete step. This forces wizard state to live server-side
  in `projects.settings`, not only in client state — a cold reload must
  reconstruct the flow.
- **Create is idempotent per wizard session.** The client generates one
  session key when the wizard mounts and sends it with every draft attempt.

## Idempotency without a new column

Store the client's key at `settings->>'wizardSessionKey'` and look it up
before inserting. It is wizard bookkeeping, not a domain concept, and
`settings` is already where request-to-request state lives.

Scope the lookup by workspace so a key guessed from another tenant cannot
match, and return `(nil, nil)` on a miss — a miss is the normal first-create
path, not an error.

The duplicate this prevents is real: a create-then-render pair inside one
`try` block leaves a created project behind when the render call fails, and
clicking the button again creates a second one.

**Register the draft-create route from the kind-registry loop in
`main.go`**, alongside the other project routes, so a kind added later
cannot forget it — the same reason the generic/motion-graphics create split
keeps dropping fields.

**The session key is SERVER-owned even though it lives in a client-writable
blob.** Re-assert it from the existing row after merging a client's patch;
accepting it verbatim lets one wizard session repoint its key at another
session's project.

## Read the live FK graph before writing the migration

Grepping the migration that CREATEd a table misses later `ALTER`s, and the
graph is always deeper than it looks. Dump it:

```sql
SELECT conrelid::regclass::text, confrelid::regclass::text, conname,
       CASE confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'a' THEN 'NO ACTION'
                        WHEN 'n' THEN 'SET NULL' WHEN 'r' THEN 'RESTRICT'
                        ELSE confdeltype::text END
  FROM pg_constraint
 WHERE contype='f' AND connamespace='content'::regnamespace
 ORDER BY 2,1;
```

Note `ORDER BY 2,1` — ordering by a column ALIAS fails here (`column
"parent" does not exist`), because `ORDER BY` cannot see aliases assigned
in the same SELECT when they are cast expressions.

Three things that graph tells you, each of which broke a first draft:

- **`ON DELETE SET NULL` on a parent link does not merely PERMIT orphans,
  it MANUFACTURES them** — deleting the parent silently orphans the child
  instead of removing it. `content.external_audio.project_id` was exactly
  this. Re-point to `CASCADE` when the child is meaningless without its
  parent, and check `confdeltype` on every child rather than assuming.
- **A `NO ACTION` edge pointing INTO the table you are clearing blocks the
  delete.** `content.renders.output_asset_id -> content.assets` aborts a
  bare `DELETE FROM content.assets` with `renders_output_asset_id_fkey`;
  detach the pointer first (`UPDATE … SET fk = NULL WHERE fk IN (…)`). An
  edge already declared `SET NULL` (`content.series.cover_asset_id`) needs
  no handling.
- **Delete children before parents**, and remember that a table which never
  had the column means *every* existing row is an orphan.

**Verify the column name against `information_schema` before referencing it
in a migration.** A guessed name fails the whole migration at run time; the
naming is not guessable across tables (`content.quality_scores` uses
`subject_kind`, not `subject_type`).

## Verify as the APP role, and round-trip the migration

goose runs as the superuser, so testing as the superuser proves nothing
about runtime grants. After `goose up`:

```bash
psql "postgres://openstudio@localhost:5432/openstudio?sslmode=disable" \
  -t -A -c "SELECT count(*) FROM content.<table>;"
```

Then run `goose down` followed by `goose up` — a migration that cannot roll
back is a trap, and the down path is where a dropped constraint gets
forgotten.

Assert the invariant mechanically rather than eyeballing it: join
`information_schema.columns` across every child table and confirm each
reports `is_nullable = NO`.

## Threading the new required field through Go

**Guard in the store, above the FK.** A missing id should return
`fmt.Errorf("…: projectID is required")`, not reach Postgres — an FK
violation surfaces as a 500 naming a constraint, which reads as an
infrastructure fault rather than the caller error it is.

**Let the compiler find the call sites.** Widening the signature turns
every caller into a build error, which is a complete list. Adding an
optional field instead leaves silent omissions.

**Put the ownership check in the SHARED middleware, not per handler.** In
`apps/api/stage_guard.go`, after the bounded body read and BEFORE moderation
and generation. Flow strictness is a UI concern, but a public API key
bypasses the UI entirely. Per-handler checks also drift: a stage added later
silently will not check. Ordering it before moderation means an invalid
project costs no inference and no credits, and another tenant's id returns
NOT FOUND (never FORBIDDEN) — distinguishing them confirms which ids exist.

**Nil-check the store inside the middleware.** Dereferencing it panics the
request on a misconfigured server, and a panic in the shared guard makes
*every* stage unreachable while leaking a stack trace.

**Audit for a second, unguarded create path.** `handleCreateScript` in
`apps/api/content.go` predates the middleware and does not run behind it, so
it has to repeat the project check or it remains a second orphan factory —
the same "two handlers for one concept" trap that silently drops fields.

**A single-field probe struct ignores unrelated malformed JSON.** Decoding
`{projectId}` alone still succeeds when another field has the wrong type,
because `encoding/json` never type-checks fields the target struct does not
declare. That is what keeps the guard from rejecting a valid request with a
misleading "projectId is required" — pin it with a test rather than
assuming either behaviour.

## Saving and resuming wizard progress

Progress persists into `projects.settings` under its own namespace key as
the user advances; the resume page reads it server-side so the first paint
already has the restored state (a client-side fetch flashes an empty wizard
first, which reads as "my work is gone").

**Save fire-and-forget, never blocking navigation.** A failed PATCH costs
the user re-picking a look; blocking Next on a flaky request costs them the
step. Log the failure so a systematically broken save is still visible.

Deserialisation rules, all of which are load-bearing:

- **Never trust the stored shape.** The blob is written by older versions of
  the code, by other handlers, and by the server. Fall back to the default
  on a wrong type — a crash or an invisibly-invalid state is worse than a
  reset field.
- **Never restore a review/approval GATE flag from storage.** The
  audio-reviewed flag gates the expensive render; a resumed session has
  heard nothing in this sitting. Restore the artefact itself so it can be
  replayed, and make the user satisfy the gate again.
- **Derive status from the artefact, not from the stored status string.** A
  stored `ready` with no audio key renders a player that cannot play and a
  gate the user is unable to satisfy.
- **A dedicated column beats a copy in the blob.** Prefer
  `projects.title` over a stale `settings.title`, since a rename through
  another surface only updates the column.
- **Normalise array members, not just the array.** A `voiceIds` entry that
  is `null` passes a truthiness filter as "a voice was chosen".

**Land the user on the EARLIEST incomplete step, not the furthest
reachable.** Dropping them at the last reachable step skips an earlier gap,
leaving a disabled Next whose explanation is three steps behind them.

**Moving a requirement between steps means re-attributing it, not copying
it.** When the title moved from a field floating above the wizard into step
1, the Review step had to STOP checking it — otherwise the same problem is
reported against the wrong step and sends the user to Review to fix
something only step 1 can fix. A test asserting "Review owns requirement X"
becomes wrong at that moment; re-point it at the new owner rather than
relaxing it.

## Expect fixture churn, and do not automate it

A new required field breaks every test that built the old shape. That
breakage is the guard working, not a regression — but fix the fixtures by
hand, or at a shared helper.

**Rewriting test bodies with regex costs more than editing them.** Three
cascading failures, each masking the next:

1. `\s*` and `\s+` alternatives both matched padded keys -> duplicate map key.
2. An anchor requiring a newline after the state constructor missed a line
   with a trailing comment -> undefined variable.
3. A "no declaration means no DB" heuristic then fed that function a fake
   placeholder id -> 404 from a test that should have passed. A heuristic
   patched over the previous bug's symptom.

Which fixture a test needs depends on WHICH state helper built it (a
DB-backed state needs a real row; a no-DB state needs a literal), and that
is per-function context a pattern match cannot see. Prefer adding the field
to a shared request helper so one edit covers every call site.

**Inserting a check reorders error precedence, so some assertions now name
the wrong field.** A test expecting "missing scriptId" gets "projectId is
required" because the new guard fires first. Give those tests a valid
project so they exercise what they are actually about — do NOT widen the
expected status to include the guard's rejection, which makes the test pass
without testing the thing.

**A test asserting input validation on a state with no database can no
longer reach that validation.** Give it a real database; the real server
always has one.

**Seed the foreign WORKSPACE row before the foreign project.** Cross-tenant
isolation tests that invent a workspace id fail the FK, hit `t.Skipf`, and a
skip reads as PASS on the package summary line — so isolation looks tested
when it is not.
