# RLS pattern for new content.* migrations

Confirmed from migrations 00043 (social_publishing), 00051 (rls_enforcement), 00057 (storage_usage), 00058 (captioned_clip).

## The pattern

```sql
-- 1. Enable + policies.
ALTER TABLE content.<t> ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON content.<t>
  FOR ALL TO openstudio_app
  USING  (<predicate>)
  WITH CHECK (<predicate>);

CREATE POLICY service_bypass ON content.<t>
  FOR ALL TO openstudio_service USING (TRUE) WITH CHECK (TRUE);

-- 2. Force (so owner connections are also subject to policies
--    unless they are explicitly BYPASSRLS).
ALTER TABLE content.<t> FORCE ROW LEVEL SECURITY;

-- 3. Re-OWN to openstudio so FORCE actually bites on the owner-pool
--    connection. Match the DO-block style in 00043/00057/00058.
DO $$ BEGIN EXECUTE 'ALTER TABLE content.<t> OWNER TO openstudio'; END $$;

-- 4. Explicit grants (default-privileges from 00051 cover new tables but
--    be explicit for review):
GRANT SELECT, INSERT, UPDATE, DELETE ON content.<t>
  TO openstudio_app, openstudio_service;
```

## The predicate

- **Table carries `workspace_id` directly** (projects, assets, external_audio, …):
  `workspace_id = platform.current_workspace()`
- **Child table** (no workspace_id, hangs off a parent):
  `EXISTS (SELECT 1 FROM content.<parent> p WHERE p.id = <child>.<parent>_id AND p.workspace_id = platform.current_workspace())`
- content.assets DOES carry workspace_id — cache tables hanging off assets EXISTS-through-assets, not through projects, for shortest path.

## Gotchas

- **Never use `current_setting('app.workspace_id', TRUE)` directly.** The repo helper is `platform.current_workspace()`. Using the raw GUC bypasses the helper's null/missing handling and silently disables isolation when the GUC is unset.
- **Target role is `openstudio_app`, not `app_user` or `authenticated`.** Those are not real roles in this schema.
- **Service bypass is a separate policy, not a role flag.** The role `openstudio_service` has BYPASSRLS, but we still write the policy so a tester role sees it on `\d` output.
- **Missing the owner re-assign silently makes FORCE a no-op.** New tables default to the migrating user; without the DO-block, the owner's BYPASSRLS defeats FORCE for every connection using that role.
- **FORCE RLS enumeration in 00051 is NOT dynamic.** New tables are NOT auto-added to that list. Each new migration must add its own `ALTER TABLE ... FORCE ROW LEVEL SECURITY` for its own tables.
- **Keep policy names literally `tenant_isolation` and `service_bypass` — do NOT rename them when the table is renamed.** `services/db/store/rls_isolation_test.go` is a structural guard that enumerates every content.* table and asserts each one has policies with exactly those names (Postgres permits duplicate policy names across tables, so there is no uniqueness pressure to prefix them). A rename-table migration that also does `ALTER POLICY tenant_isolation ON content.<t> RENAME TO <newname>_tenant_isolation` passes `goose up` and `psql \d` fine, then blows up `go test ./services/db/...` with `policy name mismatch`. Fix on a stale DB: `ALTER POLICY <newname>_tenant_isolation ON content.<t> RENAME TO tenant_isolation;` (+ `service_bypass`) as the `sa-vm` superuser, because `openstudio` can't ALTER POLICY on tables it does not own under FORCE RLS.

## Verifying a new migration

```bash
# 1. Apply.
cd services/db
goose -dir migrations postgres "$DATABASE_URL" up

# 2. Spot-check policies + FORCE on the new table.
psql "$DATABASE_URL" -c '\d content.<t>'
# Expect footer lines:
#   Policies:
#     POLICY "service_bypass" FOR ALL TO openstudio_service USING (true) WITH CHECK (true)
#     POLICY "tenant_isolation" FOR ALL TO openstudio_app USING ... WITH CHECK ...
#   Access method: heap
#   Options: ... (forced row security enabled)

# 3. Run the generic cross-tenant isolation test.
DATABASE_URL=... go test -run TestRLS ./services/db/store/...
```

## Manual RLS smoke test inside psql

```sql
-- Switch to the app role with a workspace GUC set.
SET ROLE openstudio_app;
SELECT platform.set_workspace('ws_A');
INSERT INTO content.<t> (...) VALUES (...);        -- succeeds, project in ws_A

SELECT platform.set_workspace('ws_B');
SELECT * FROM content.<t> WHERE id = '<the id>';   -- returns 0 rows

RESET ROLE;
```

## When a Go store test cannot easily switch roles

The test harness `openTestStore` connects as the `openstudio` owner (BYPASSRLS). Switching to `openstudio_app` via `SET LOCAL ROLE` inside a pgx pool connection fights the pool's connection reuse. Acceptable to SKIP a per-table RLS unit test and lean on `services/db/store/rls_isolation_test.go` (the generic harness that enforces policy+FORCE on every workspace_id-carrying table) plus the migration-time manual psql check above. Leave a `TODO(RLS test)` comment with the rationale.
