---
name: postgres-row-level-security
description: "Postgres RLS: policies, ownership bypass, migrations."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [postgres, rls, migrations, security]
    related_skills: []
---

# Postgres Row-Level Security — policies, ownership, migrations

Always-on rules for schemas that use `ENABLE ROW LEVEL SECURITY` for multi-tenant isolation. Captures the pitfalls that don't show up in tutorials but bite when a migration runs under a different role than the app.

## When to Use

- Adding a new table under a schema whose sibling tables use RLS.
- Writing or reviewing a goose / sqlc / Atlas / Flyway migration for an RLS-enabled schema.
- Debugging `permission denied for table` (SQLSTATE 42501) or `new row violates row-level security policy` from the app when the same query succeeds as superuser.
- Designing tenant-isolation policies for the first time.

## Standing rules

1. **Any migration that `CREATE TABLE` inside an RLS-enabled schema MUST end with `ALTER TABLE <schema>.<table> OWNER TO <app_role>;`.** Postgres treats the table owner as bypassing RLS whenever `relforcerowsecurity = false` (the default). If the migration is applied by a superuser role (a real one during ops, or a local dev connecting as themselves), the new table is owned by that role — not the app — and the app role is now subject to RLS that was silently satisfied by ownership on every other table in the schema. Symptom: writes and reads through the app fail with 42501, but the same query as superuser or via `SET ROLE app` (if configured) succeeds. Add an ownership check to your migration lint if you have one; otherwise make ownership the last statement in every `CREATE TABLE` migration.
2. **Prefer `ALTER TABLE ... FORCE ROW LEVEL SECURITY` when you actually want RLS to apply to the owner too.** Without `FORCE`, an RLS setup that "works" in staging is often an accident of ownership. If your policy is meant to isolate tenants even from the role that owns the table, set FORCE — then every query is subject to policy, ownership is not an escape hatch, and a role-change during migration cannot silently bypass isolation.
3. **Every RLS policy binds to a ROLE via its `TO` clause; the app's connection role must actually be listed.** `CREATE POLICY tenant_isolation ... TO openstudio_app` does nothing for a session connected as `openstudio`. Either make the app role a member of the policy role (`GRANT openstudio_app TO openstudio`), connect the app as the policy role directly, or drop the `TO` clause (defaults to PUBLIC). Verify with `SELECT policyname, roles FROM pg_policies WHERE schemaname='...' AND tablename='...'` and cross-reference with `SELECT current_user` from the app's connection.
4. **After a migration adds a table to an RLS schema, verify ownership consistency across siblings before marking the change done.** `SELECT c.relname, r.rolname AS owner, c.relrowsecurity, c.relforcerowsecurity FROM pg_class c JOIN pg_roles r ON r.oid=c.relowner JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='<schema>' ORDER BY relname;` — every row should show the same owner and the same RLS/FORCE settings. A mismatched owner column is the smoking gun for the class of bug this skill exists to catch.
5. **Fix RLS ownership drift in a durable follow-up migration, never as a one-off `psql` command against the running DB.** The `ALTER TABLE ... OWNER TO <app_role>` needs to be reproducible in every environment (CI, staging, prod, a future teammate's laptop). Land it as its own numbered migration alongside a comment explaining why; do NOT rely on a runbook step, an ops chat message, or your shell history.
6. **Session variables that policies read MUST be scoped so a pooled connection cannot leak the previous tenant's identity to the next borrower.** Two valid shapes:
   - **Transaction-local:** `SET LOCAL app.tenant_id = '...'` as the first statement inside every request transaction. Clears on `COMMIT`/`ROLLBACK`. Works with any driver. Required when running behind pgbouncer in *transaction* mode.
   - **Connection-local via pool hooks (pgx):** set the GUC in a pool `BeforeAcquire` hook from a context value, and clear it in `AfterRelease` so a conn returned to the pool and borrowed later by a pre-auth path starts clean. `SET` alone (without `AfterRelease`) is the leak; the pair is safe. Lets existing non-transactional call sites keep working unchanged. Does NOT work behind pgbouncer transaction mode — the conn is handed back mid-request.
   Never set the GUC with a bare `SET` on connect and no reset path — that is the leak this rule exists to prevent.
7. **Grant `service_bypass` policies to a distinct role, never to PUBLIC or the app role.** Background workers, migrations, and admin scripts need a role that bypasses tenant isolation. Give it its own login (`openstudio_service`), add `CREATE POLICY service_bypass ... TO openstudio_service USING (TRUE) WITH CHECK (TRUE)`, and connect the specific processes that need it under that DSN. Never grant that role to the app-facing connection or to a shared pool.
8. **An app that connects as the table owner has decorative RLS, no matter how many policies exist.** The failing audit is three queries: `SELECT rolcanlogin, rolbypassrls FROM pg_roles WHERE rolname IN ('<app>', '<owner>')` — if the app role can't log in or the owner role doesn't have `BYPASSRLS` set explicitly, the system is relying on default ownership-bypass, which `FORCE ROW LEVEL SECURITY` on each table silently defeats. Also grep the codebase for `set_config(` or `SET.*app\.` — zero hits means the GUC is never populated and every policy predicate evaluates against NULL. The fix is: give the owner role explicit `BYPASSRLS`, give the app role `LOGIN` + CONNECT, add `FORCE ROW LEVEL SECURITY` to every tenant table so the owner-pool escape hatch is deliberate not accidental, and populate the GUC on every request.
9. **Keep a CI guard that enumerates tenant tables from `pg_catalog` and fails on a missing policy or missing FORCE.** The query shape: find every table in your tenant schemas with a `workspace_id` (or equivalent) column, then assert each has a `tenant_isolation` policy in `pg_policies` and `relforcerowsecurity = true` in `pg_class`. A new workspace-scoped table that lands without a policy is the exact regression mode this skill exists to catch; code review will not catch it reliably, the schema will. See `references/go-two-pool-enforcement.md` for the full test skeleton.
10. **Platform / cross-tenant / pre-auth tables stay OUT of RLS, deliberately.** Session lookups, API-key lookups, magic-link verify, user-by-email, workspace-member lookups all run before any workspace is known. Putting those tables under tenant RLS forces a chicken-and-egg workaround on every path. Document the exclusion so the gap is intentional, not forgotten; enforce tenancy on them in application code by scoping every query by `user_id` or `workspace_id` explicitly.

## Related depth

- `references/go-two-pool-enforcement.md` — the two-pool routing pattern for pgx (owner + app with `BeforeAcquire`/`AfterRelease`), middleware context stamping, and the CI-guard test skeleton. Use this when wiring Go pgx apps.


## Verification recipe for an RLS-enabled table you just added

```sql
-- Ownership: every table in the schema should share an owner.
SELECT c.relname, r.rolname AS owner, c.relrowsecurity, c.relforcerowsecurity
FROM pg_class c JOIN pg_roles r ON r.oid=c.relowner
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='<schema>' ORDER BY relname;

-- Policies: does the app's connection role match a TO clause?
SELECT tablename, policyname, roles::text, cmd
FROM pg_policies WHERE schemaname='<schema>' AND tablename='<new_table>';

-- Live check as the app user (not as superuser):
PGPASSWORD=... psql -U <app_role> -c 'INSERT INTO <schema>.<new_table> ...'
```

If the app's role isn't in `roles` AND doesn't own the table, INSERT will fail with SQLSTATE 42501 — the exact class of bug this skill exists to catch.

## Common rationalisations

| Excuse | Reality |
|---|---|
| "The policy uses `TO app_role`, so the app is covered." | Only if the app connects AS `app_role`. Check `SELECT current_user` from the pool. |
| "Every other table in the schema works, so the new one will too." | Others work because the app role owns them and bypasses RLS. New table owned by a different role does not get that bypass. |
| "I'll fix ownership manually with psql on prod." | Won't survive a rebuild, a rollback, or a new environment. Land the ALTER OWNER as a migration. |
| "I set the tenant id with `SET` at connect time." | Pooled connections leak that setting to the next tenant. `SET LOCAL` inside a transaction is the only safe pattern. |
