# Schema & migrations — placement, naming, scope pitfalls

Topical reference loaded by `openstudio-development` when you are writing a Postgres migration, picking a schema for a new table, or planning a feature that touches `services/db/migrations/`.

## Schema taxonomy — pick the right one, don't invent new ones

The DB has four schemas with stable meanings. New tables go in the one that matches the data, not the one that matches the vibe of the feature.

| Schema | Meaning | Examples |
|---|---|---|
| `platform.*` | Auth, identity, workspaces, memberships, sessions. The things the request lifecycle needs before any product code runs. | `platform.users`, `platform.workspaces`, `platform.workspace_members`, `platform.sessions`, `platform.notification_prefs` |
| `content.*` | Workspace-scoped product data: projects, their artefacts, and anything that joins them. This is where 90% of new tables land — kanban boards, comments, checklists, social accounts, publications, webhooks, series all live here even though they feel like "collaboration" or "workflow" rather than "content". | `content.projects`, `content.renders`, `content.scenes`, `content.series`, `content.publications`, `content.social_accounts`, `content.webhooks`, `content.scripts`, `content.characters` |
| `billing.*` | Credits ledger, lots, reservations. | `billing.lots`, `billing.ledger` |
| `catalog.*` | Product catalog entries (SKUs, kinds). | `catalog.*` |

**Rules:**
- A new workspace-scoped table belongs in `content.*` by default. The precedent set by `series`, `social_accounts`, `publications`, `webhooks` means collaboration-and-workflow tables already live there.
- Do not propose a new schema (`workspace.*`, `collab.*`, `kanban.*`) for one feature. Reasons: (a) `platform.workspaces` already owns the "workspace" name; a `workspace.*` schema is permanently ambiguous in reviews and logs. (b) cross-schema FKs work but add noise to every GRANT and RLS policy. (c) carving one schema for one feature is a one-off exception, not a taxonomy. Only propose a new schema alongside an ADR that migrates the collaboration-adjacent `content.*` tables with it.
- When the user asks "should we use `\content`?" or "should this be its own schema?", the honest answer is almost always "use `content.*`, matching the existing pattern" — unless you have a concrete reorg plan.

## Migration anatomy that works here

Minimum shape, copying `00043_social_publishing.sql` / `00006_series_characters.sql`:

1. `-- +goose Up` / `-- +goose StatementBegin` wrapping the whole up block.
2. `CREATE TABLE content.<name> (...)` with `workspace_id TEXT NOT NULL REFERENCES platform.workspaces(id) ON DELETE CASCADE` on every workspace-scoped table.
3. Indexes immediately after each `CREATE TABLE`.
4. `GRANT SELECT, INSERT, UPDATE, DELETE ON <all new tables> TO openstudio, openstudio_app, openstudio_service;` — **all three roles**, every new table. The app pool connects as `openstudio` (owner of most `platform.*`) for non-RLS paths and only switches to `openstudio_app`/`openstudio_service` inside `SET LOCAL ROLE` transactions. A grant list that names only the two role identities passes `goose up` and the full unit suite (both run as superuser), then returns `SQLSTATE 42501 permission denied` the first time real traffic hits the non-RLS path (session mint, auth lookup, anything outside an RLS-scoped tx). Before accepting the migration, in a `psql` connected as `openstudio` run `\dp <schema>.<table>` and confirm all three roles appear.
5. `ALTER TABLE <name> ENABLE ROW LEVEL SECURITY;` for each table.
5a. `ALTER TABLE <name> OWNER TO openstudio;` (or a `DO $$ BEGIN EXECUTE format('ALTER TABLE %I.%I OWNER TO openstudio', 'content', '<name>'); END $$;` block when scripting many at once). Without this, a table owned by whichever role ran `goose up` sits outside the FORCE-RLS backstop installed by `00051_rls_enforcement.sql`, and `ALTER TABLE ... FORCE ROW LEVEL SECURITY` later catches nothing on the owner-side connection. 00043 and 00057 both re-OWN new tables for exactly this reason — mirror that.
6. `tenant_isolation` + `service_bypass` policies for each table. The tenant policy predicate calls the helper `platform.current_workspace()`, NOT `current_setting('app.workspace_id', TRUE)` directly — the helper centralises the GUC name and the TRUE/missing-is-not-an-error semantic, and the app pool's BeforeAcquire hook populates it per request. Scope through parent when the table has no `workspace_id` of its own: `USING (EXISTS (SELECT 1 FROM content.<parent> p WHERE p.id = <table>.<fk> AND p.workspace_id = platform.current_workspace()))`, with the same predicate in `WITH CHECK`. See `content.series_episodes` (through `content.series`) and `content.publication_metrics` (through `content.publications`).
7. `-- +goose StatementEnd`.
8. `-- +goose Down` / `-- +goose StatementBegin` with `DROP TABLE IF EXISTS content.<name>;` in reverse FK order, then `-- +goose StatementEnd`.
9. Verify up/down/up round-trip: `GOOSE_DRIVER=postgres GOOSE_DBSTRING="postgres://sa-vm@localhost:5432/openstudio?sslmode=disable" goose -dir migrations up` then `down` then `up`. All three must say OK before you commit.

**File numbering:** `ls services/db/migrations/ | tail -1` gives you the next number. Zero-pad to 5 digits (`00046_name.sql`). goose will not pick up a wrong-numbered file.

## Fixing a shipped migration — new row, not in-place edit

Once a migration has merged to main, every other dev's DB (and CI, and the user's local) has already applied it. Editing that file in place — rewriting a `CREATE TABLE`, changing an `INSERT`'s payload for a seed row, altering the `Down` block — does nothing on any system that already ran the old version: goose records only the version number, not the file's content hash. The symptom is a fix that works perfectly on a fresh DB (your reset laptop, CI's ephemeral postgres) and silently does nothing everywhere else. For the author it looks shipped.

The rule: a shipped migration is immutable; the fix is a NEW migration at the next number that supersedes it.

- Seed-row payload wrong (prompt body enum, system-prompt text, catalog row) → new migration doing `UPDATE <table> SET body = $$...$$::jsonb WHERE id = '<same-id>'`, with the Down block restoring the previous body verbatim.
- Column type/constraint wrong → new migration with `ALTER TABLE` or add-column-copy-drop-rename, not an edit to the original `CREATE TABLE`.
- Policy predicate wrong → new migration dropping and recreating ONLY that policy by its structural name (`tenant_isolation`/`service_bypass` — see RLS reference; renaming them breaks `rls_isolation_test.go`).

The only case for editing a migration in place is when it has NOT been pushed off your branch yet (no PR, no sibling worktree pulling it) — then rolling it back locally and rewriting it is cleaner than carrying a two-migration pair for one feature. The moment the branch is pushed, treat the file as frozen.

Verification for a superseding migration: `goose up` on a DB sitting at the pre-fix version AND on a fresh DB must both end on the same final state (`pg_dump --schema-only` + spot-check of the fixed row). The up/down/up round-trip from the previous section is not enough — the pre-fix state is the one that actually ships to other developers.

## Reserved-word column names — the usual traps

Postgres accepts some reserved words in `CREATE TABLE` but breaks on them in expressions, DO blocks, or tooling. Rename at design time, not after it bites:

- `row` → use `row_slot`, `row_index`, `ordinal`.
- `user` → use `author_user_id`, `owner_user_id`, `added_by`.
- `order` → use `position`, `rank`, `sort_key`.
- `type` → use `kind`, `category`, `<domain>_type`.
- `check` → use `check_name`, `assertion`.
- `value` → use `<thing>_value`, `payload`, `amount`.
- `limit`, `offset`, `select`, `where` — same story.

Quick smoke: write the migration, then try a `SELECT <column> FROM <table>` in `psql`. If it needs double quotes, rename.

## Detecting FK / unique-violation errors from pgx — use the TYPED check

A pgx query that violates a constraint returns a `*pgconn.PgError` whose `.Code` is the Postgres SQLSTATE. Common codes worth skipping-vs-failing on:

| Code | pgerrcode constant | Meaning |
|---|---|---|
| `23503` | `ForeignKeyViolation` | FK target gone (deleted-row race) |
| `23505` | `UniqueViolation` | Row already there (idempotency) |
| `23502` | `NotNullViolation` | Required column null |
| `23514` | `CheckViolation` | Check constraint failed |

**Use the typed check, never `strings.Contains(err.Error(), "23503")`:**

```go
import (
    "errors"
    "github.com/jackc/pgerrcode"
    "github.com/jackc/pgx/v5/pgconn"
)

func isFKViolation(err error) bool {
    if err == nil { return false }
    var pgErr *pgconn.PgError
    return errors.As(err, &pgErr) && pgErr.Code == pgerrcode.ForeignKeyViolation
}
```

`pgconn` is already in `go.sum` transitively via `pgx/v5`; `pgerrcode` must be added (`go get github.com/jackc/pgerrcode`). pgx today formats the SQLSTATE into `.Error()`, so a string match passes — but any wrapper that re-formats the message (`fmt.Errorf("while inserting X: %w", err)` is fine because `%w` preserves `errors.As`; a logger that re-stringifies without `%w` is NOT fine, and `errors.New(err.Error())` definitely isn't) silently flips the string check to false. The typed check is immune: `errors.As` unwraps through any number of `%w` layers.

Tests become clearer too — a `fakeErr("ERROR: ... (SQLSTATE 23503)")` plain error can't pretend to be a typed violation, which was the real pitfall under the string-match form.

## RLS vs application tenancy

`services/db/store/store.go` has a top-of-file comment that is the authoritative statement: RLS policies in migrations are a defense-in-depth stub, not the live gate. The app role (`openstudio`) OWNS the tables and bypasses RLS; nothing sets `platform.current_workspace()`. **Every workspace-scoped query in `services/db/store/*.go` MUST carry an explicit `WHERE workspace_id = $N`.** Read that header before writing any new store method. A forgotten predicate is a cross-tenant data leak with zero backstop in Postgres or CI.

Migrations still carry the policies because `docs/PRODUCTION-READINESS.md #0` plans to flip to a non-owner login role + per-tx GUC + FORCE RLS. Keep the policies honest so that flip is a one-day migration.

## Scope expansion while planning: rewrite, don't bolt

When the user steers mid-plan with a widening correction (new visibility model, new entity, new invariant) — do NOT patch the existing design and keep coding. Procedure:

1. Stop writing code immediately. Any schema work already done against v1 assumptions is throwaway unless it coincidentally matches v2.
2. Run one more `clarify` batch (3–5 questions) to lock the shape: invariants, auth model, state-machine shape, migration-level consequences.
3. Rewrite the plan file (`docs/plans/YYYY-MM-DD-feature.md`) in place as v2. Delete the stale version; `write_file` will refuse an overwrite of a file not fully read, so `rm` first or `read_file` the whole thing before overwriting. Never leave "UPDATE: actually..." additions under the stale text.
4. Re-verify the migration + Go-store signatures against v2 before resuming code.

The plan file is the artifact that keeps v1-brained code out of a v2 schema. The user explicitly chose "detailed plan file first" for schema-heavy features for exactly this reason.
