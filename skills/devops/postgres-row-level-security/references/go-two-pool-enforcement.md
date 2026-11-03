# Making RLS real in a Go + pgx app — the two-pool pattern

Use this when you have an existing codebase whose RLS policies are decorative — present on the tables but bypassed because the app connects as the table owner, the policy role has no LOGIN, and the GUC the predicates read is never set. The migration from "policies exist" to "policies enforce" is bigger than it looks: `FORCE ROW LEVEL SECURITY` alone will break every query because the owner was quietly bypassing until now.

## Architecture — two pools, one routing wrapper, context stamping

- **Owner pool** connects as the table-owner role (e.g. `openstudio`) with explicit `BYPASSRLS` set at the ROLE level. Used for pre-auth lookups (session resolve, API-key by prefix, user-by-email), migrations, sweepers, and anything genuinely cross-workspace.
- **App pool** connects as a dedicated role (e.g. `openstudio_app`) with `LOGIN` and no `BYPASSRLS`. Used for every request-path query where a workspace is known. A pool-level `BeforeAcquire` hook reads the workspace from the request context and runs `set_config('app.workspace_id', $1, false)` on the connection; `AfterRelease` clears it so a later borrower from a pre-auth path starts clean.
- **Routing wrapper** implements the same `Exec/Query/QueryRow/Begin/BeginTx` surface the store already uses. If the context carries a workspace, route to the app pool; otherwise route to owner. Hundreds of existing `s.Pool.Exec(ctx, ...)` call sites keep working unchanged — the only new obligation is stamping the workspace into the context at the middleware layer.

This is the pattern to reach for when wrapping every call in `BEGIN; SET LOCAL app.tenant_id=...; ...; COMMIT` would mean changing every store method. It costs one extra pool and two hooks, and it fits pgx cleanly. **It does not work behind pgbouncer transaction mode** — the connection goes back to the pool mid-request and the next statement for that request runs on a different conn with the wrong GUC. For transaction-mode poolers, the SET LOCAL + explicit tx pattern (standing rule 6) is the only safe option.

## Sequence

1. **Audit the current state.** Three checks:
   ```sql
   SELECT rolname, rolcanlogin, rolbypassrls FROM pg_roles
   WHERE rolname IN ('openstudio','openstudio_app','openstudio_service');

   -- Which tenant tables have policies vs don't?
   SELECT c.relnamespace::regnamespace||'.'||c.relname, c.relrowsecurity, c.relforcerowsecurity,
          (SELECT count(*) FROM pg_policies p
           WHERE p.schemaname=c.relnamespace::regnamespace::text AND p.tablename=c.relname) AS policies
   FROM pg_class c JOIN pg_attribute a ON a.attrelid=c.oid
   WHERE c.relkind='r' AND a.attname='workspace_id'
     AND c.relnamespace::regnamespace::text IN ('content','billing','platform')
   ORDER BY 1;
   ```
   Expect: app role `rolcanlogin=f`, owner `rolbypassrls=f` (relying on ownership), zero `relforcerowsecurity=t`.

2. **Decide tenant vs non-tenant schemas up front.** Not every schema with a `workspace_id` column is a good RLS candidate. Pre-auth lookups (sessions, api_keys, magic_links) must stay on the owner pool — defending them with RLS means a second `app.user_id` GUC and user-scoped policies, which is a bigger project. Document the exclusion in the migration so the gap is deliberate.

3. **One enforcement migration.** Combine every change into one migration so the system never spends time in a half-enforced state:
   ```sql
   ALTER ROLE openstudio_app WITH LOGIN;
   ALTER ROLE openstudio BYPASSRLS;              -- explicit > implicit
   ALTER ROLE openstudio_service BYPASSRLS;

   -- GRANT CONNECT ... cannot bind a variable; use DO $$ EXECUTE format(...) $$.
   DO $$ BEGIN
     EXECUTE format('GRANT CONNECT ON DATABASE %I TO openstudio_app, openstudio_service',
                    current_database());
   END $$;

   -- Policies on any tenant table that was missed before.
   ALTER TABLE content.whatever ENABLE ROW LEVEL SECURITY;
   CREATE POLICY tenant_isolation ON content.whatever
     FOR ALL TO openstudio_app
     USING (workspace_id = platform.current_workspace())
     WITH CHECK (workspace_id = platform.current_workspace());
   CREATE POLICY service_bypass ON content.whatever
     FOR ALL TO openstudio_service USING (TRUE) WITH CHECK (TRUE);

   -- Indirect tables (no workspace_id, hang off a parent).
   CREATE POLICY tenant_isolation ON content.scenes
     FOR ALL TO openstudio_app
     USING (EXISTS (SELECT 1 FROM content.projects p
                    WHERE p.id = scenes.project_id
                      AND p.workspace_id = platform.current_workspace()))
     WITH CHECK (EXISTS (...));

   -- FORCE RLS on EVERY tenant table — list each explicitly, generated once.
   ALTER TABLE content.projects FORCE ROW LEVEL SECURITY;
   -- ...

   -- Idempotent grants + default privileges so new tables inherit.
   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA content, billing
     TO openstudio_app, openstudio_service;
   GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA content, billing
     TO openstudio_app, openstudio_service;
   ALTER DEFAULT PRIVILEGES FOR ROLE openstudio IN SCHEMA content
     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES
     TO openstudio_app, openstudio_service;
   ```
   `ALTER ROLE ... BYPASSRLS` requires superuser. Note it in the migration header so the operator runs it under the right role.

4. **Pool wrapper + hooks.** Keep the field name the store already exposes (`Store.Pool`) and make it a routing wrapper, so existing call sites don't move:
   ```go
   type routingPool struct {
       owner *pgxpool.Pool
       app   *pgxpool.Pool // nil in legacy single-pool mode
   }

   func (p *routingPool) pick(ctx context.Context) *pgxpool.Pool {
       if p.app != nil && workspaceFromCtx(ctx) != "" { return p.app }
       return p.owner
   }

   // Exec / Query / QueryRow / Begin / BeginTx / Close delegate to pick(ctx).

   // Owner() + App() escape hatches for ledger-like components that take
   // workspace per-call and don't need routing, and for the CI guard.
   func (p *routingPool) Owner() *pgxpool.Pool { return p.owner }
   func (p *routingPool) App()   *pgxpool.Pool { return p.app }
   ```
   App pool configuration:
   ```go
   cfg.BeforeAcquire = func(ctx context.Context, conn *pgx.Conn) bool {
       ws := workspaceFromCtx(ctx) // "" is fine — empty GUC matches no rows
       _, err := conn.Exec(ctx, "SELECT set_config('app.workspace_id', $1, false)", ws)
       return err == nil // drop the conn on failure rather than hand over stale state
   }
   cfg.AfterRelease = func(conn *pgx.Conn) bool {
       // context.Background: request ctx may be cancelled by now.
       _, err := conn.Exec(context.Background(),
           "SELECT set_config('app.workspace_id', '', false)")
       return err == nil
   }
   ```
   Pass the GUC value as a bind parameter — never interpolate into the SQL string. `set_config` with a bound param is the clean form.

5. **One chokepoint for the context stamp.** Every middleware that mints a principal already goes through `contextWithPrincipal` (or the equivalent). Add the workspace stamp there, not at each middleware's end:
   ```go
   func contextWithPrincipal(ctx context.Context, p *auth.Principal) context.Context {
       ctx = context.WithValue(ctx, ctxPrincipal, p)
       if p != nil { ctx = store.WithWorkspace(ctx, p.WorkspaceID) }
       return ctx
   }
   ```
   Then session middleware, API-key middleware, and any combined middleware all pick up the stamp for free. A new auth path only needs to call this helper to get RLS routing automatically.

6. **Boot path falls back cleanly.** `NewWithRLS` tries to open both pools; if the app pool fails (missing role on a fresh DB, config error) fall back to `New` (owner-only) with a `slog.Warn`. The service stays up; the warn is loud enough to catch in logs. Never fail boot on an RLS wiring error — the migration order (00051 adds LOGIN) means the first deploy after this change opens the app pool successfully; subsequent deploys don't need the fallback, but keeping it means a role-reset or a hand-rolled staging DB won't take the API down.

7. **Live verification before marking done.**
   - `grep -c 'db init with RLS failed' <log>` is zero — boot is actually using the app pool, not falling back.
   - `SELECT backend_type, usename, count(*) FROM pg_stat_activity WHERE datname='<db>' AND usename IN ('<owner>', '<app>') GROUP BY 1,2` shows live app-role connections handling request traffic.
   - Hit a session-authed read endpoint, confirm correct scoped data.
   - Open psql as the app role with no GUC and confirm `SELECT count(*) FROM <tenant_table>` returns 0.

## CI guard — the regression gate

An RLS-enabled schema regresses one way: a new workspace-scoped table lands without a policy. Code review will not catch it; `pg_catalog` can. The test enumerates tables, asserts policy + FORCE, and runs a two-workspace isolation probe. Skip when the DB isn't reachable so laptop runs stay fast; CI must set `DATABASE_URL` so the test runs there.

```go
func TestRLS_EveryWorkspaceTableHasPolicyAndForce(t *testing.T) {
    s := openRLSStore(t) // Skips on dial failure.
    defer s.Pool.Close()
    ctx := context.Background()

    rows, _ := s.Pool.Owner().Query(ctx, `
        SELECT c.relnamespace::regnamespace::text || '.' || c.relname
        FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid
        WHERE c.relkind='r' AND a.attname='workspace_id'
          AND c.relnamespace::regnamespace::text IN ('content','billing')
        ORDER BY 1`)
    // ... for each schema.table:
    //   assert pg_policies has tenant_isolation for it,
    //   assert pg_class.relforcerowsecurity is true,
    //   on either failure: t.Errorf with the exact migration SQL to run.
}

func TestRLS_WorkspaceIsolation(t *testing.T) {
    // Seed as owner (bypass), then query via app pool with WithWorkspace(ctx, A),
    // expect to see A's rows only. Switch to WithWorkspace(ctx, B), expect B's only.
    // Attempt INSERT with workspace_id=B while stamped as A — expect error
    // (WITH CHECK rejects it; a forgotten workspace predicate in Go cannot smuggle
    // a cross-tenant insert past RLS).
}
```

The isolation probe matters as much as the enumeration: it verifies the GUC is actually reaching the policy, not just that the policy exists.

## Pitfalls

- **`openstudio_app` must have `GRANT CONNECT ON DATABASE`.** `LOGIN` alone is not enough — connection fails with `permission denied for database`. Add it to the migration (`DO $$ EXECUTE format(...) $$` because `GRANT ... ON DATABASE` can't take a bind parameter).
- **Default privileges only cover tables created AFTER the `ALTER DEFAULT PRIVILEGES` runs.** Issue the `GRANT ... ON ALL TABLES IN SCHEMA` once in the enforcement migration too; without it, existing tables stay unreachable to the app role.
- **FORCE RLS on indirect tables that don't carry `workspace_id`.** Scenes hang off projects; render_revisions hang off renders; board_lanes hang off boards. The parent policy on the direct table does NOT cover a direct `SELECT` on the child — RLS is per-table. Add a policy on the child whose predicate `EXISTS`s against the parent's workspace.
- **Global catalog tables (templates, system_prompts, template_groups) are not tenant data.** They have no `workspace_id`, don't need a policy, and don't need FORCE. The enumeration query above correctly ignores them.
- **Ledger / per-workspace service components should get `Pool.Owner()`, not `Pool`.** They already take `workspace_id` on every method and don't flow a request context; the routing wrapper on them would always fall to owner anyway, but naming the owner pool explicitly in the construction site makes the intent legible and survives a future refactor that could accidentally start passing workspace-stamped contexts.
- **Do not forget `GRANT USAGE ON SEQUENCES`.** `auth_audit` and other `BIGSERIAL` tables fail inserts without it. The enforcement migration must grant both tables and sequences.
- **The test's isolation probe needs the WITH CHECK verification.** USING-only policies gate reads; WITH CHECK gates writes. A policy without WITH CHECK lets a forgotten `workspace_id` in Go insert a cross-tenant row that is then invisible to its originator — the worst failure mode. Verify both halves in the test.
