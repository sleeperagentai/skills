# Grafana → Postgres datasource (co-located obs DB)

Use this when Grafana queries a Postgres database that lives on the same instance as the application's customer DB — the common shape for an "audit log in its own DB" setup. The isolation Postgres gives you by default is weaker than it looks.

## The CONNECT-to-PUBLIC trap

Postgres grants `CONNECT` on every database to the `PUBLIC` pseudo-role at creation time. A dedicated obs DB with its own owner/writer/reader roles and no table grants on customer tables is NOT isolated — the obs reader can still open a session on the customer DB. It can't SELECT anything (no grants, relations invisible), but the connection itself is more than most reviewers assume you've promised.

Strip it on both sides, during the obs provisioner so a fresh env inherits the fix:

```sql
-- Lock down the customer DB against obs roles.
REVOKE CONNECT ON DATABASE <customer_db> FROM PUBLIC;
REVOKE CONNECT ON DATABASE <customer_db> FROM <obs_owner>, <obs_writer>, <obs_reader>;

-- Lock down the obs DB against everyone else.
REVOKE CONNECT ON DATABASE <obs_db> FROM PUBLIC;
GRANT  CONNECT ON DATABASE <obs_db> TO <obs_owner>, <obs_writer>, <obs_reader>;
```

Make it idempotent (`IF EXISTS` on `pg_database` before touching the customer DB) so the obs provisioner can run before the app provisioner on a cold machine.

## Verify at runtime, not in the migration log

The migration can succeed and the isolation can still be broken (previous grants, PUBLIC still carrying CONNECT from a role template). Prove it after every provision run:

```bash
# Reader → customer DB must fail with 'permission denied for database'.
PGPASSWORD=... psql -h localhost -U <obs_reader> -d <customer_db> -c 'SELECT 1'

# Reader → obs DB must succeed.
psql "$OPENSTUDIO_OBS_DB_URL_READER" -tAc 'SELECT current_database()'

# Writer INSERT ok, writer SELECT denied; reader SELECT ok, reader INSERT denied.
```

These four checks together are the real role-isolation guarantee; the DDL alone is not.

## Grafana provisioning

In `provisioning/datasources/*.yaml`, use the READER role and resolve the password from an env var. Never check in a password or point Grafana at the owner — Grafana's connection pool is long-lived and a compromised Grafana must not be able to DELETE audit rows.

```yaml
- name: Obs (reader)
  type: postgres
  url: localhost:5432
  user: <obs_reader>
  secureJsonData:
    password: ${<OBS_READER_PASSWORD_ENV>}
  jsonData:
    database: <obs_db>       # MUST be inside jsonData for grafana-postgresql-datasource ≥ v12
    sslmode: disable         # localhost only; use require for TCP
    postgresVersion: 1800    # match the server's major
```

**`database` belongs inside `jsonData`, not at the top level, on the modern Postgres plugin.** The old shape (`database:` as a top-level yaml key) still parses without a provisioning error, which is the trap — Grafana writes the row to its SQLite with `database=""` and every query returns 'You do not currently have a default database configured for this data source. Postgres requires a default database with which to connect.' The `grafana-postgresql-datasource` plugin that shipped alongside Grafana 12 moved all connection fields under `jsonData`; blog posts and the first page of docs still show the pre-12 shape. Verify by hitting `GET /api/datasources/uid/<uid>` after provisioning — the response must show `jsonData.database: <obs_db>` AND `secureJsonFields.password: true`. Either missing = the datasource is dead no matter what the health check says.

## Credential plumbing: write a 0600 file, source before Grafana launches

`secureJsonData.password: ${OBS_READER_PASSWORD}` is a lazy string template — Grafana expands it against whatever env it sees at startup. The common failure is a provisioner that generates random passwords and echoes them to stderr, then exits; Grafana launches later with a clean env and silently resolves the var to empty. The datasource row shows `secureJsonFields: {}` (not `{password: true}`), and queries fail at the plugin layer, not provisioning.

Fix in two steps:

1. In the provisioner, persist the generated passwords to a durable 0600 file (not just an echo):

   ```bash
   state_dir="${OBS_STATE_DIR:-$HOME/.<project>/obs}"
   mkdir -p "$state_dir"
   umask 077
   cat >"$state_dir/creds.env" <<CREDS
   export OBS_OWNER_PASSWORD='${owner_pw}'
   export OBS_WRITER_PASSWORD='${writer_pw}'
   export OBS_READER_PASSWORD='${reader_pw}'
   export OBS_DB_URL='postgres://writer:${writer_pw}@localhost:5432/<obs_db>?sslmode=disable'
   export OBS_DB_URL_READER='postgres://reader:${reader_pw}@localhost:5432/<obs_db>?sslmode=disable'
   CREDS
   chmod 600 "$state_dir/creds.env"
   ```

2. In the launcher (`up.sh --obs` or equivalent), `source "$state_dir/creds.env"` BEFORE the `start_svc grafana` call so the vars are inherited by the forked Grafana. If the file is missing, call the provisioner first — don't launch Grafana against an unprovisioned stack.

This is the single source of truth for every consumer (API binary, Grafana, ad-hoc psql, retention cron). A password that only exists in a one-shot stderr echo is an unrecoverable failure mode for anyone who re-launches a component the next day.

## Retention job uses the OWNER DSN, not the writer

Writer is INSERT-only (that's the point). A retention/cleanup cron needs DELETE, which only the owner has. Give the cron its own narrow DSN and keep it out of the services' env.

## pgxpool quirk when a cleanup job sets `statement_timeout`

`pool.Exec(ctx, "SET statement_timeout = ...")` sets the timeout only on the one checked-out connection, which is returned to the pool before the next `Exec`. The next batched DELETE runs on a different conn with the default timeout. Set it as a RuntimeParam on the pool config instead, so every conn opens with the limit:

```go
cfg, _ := pgxpool.ParseConfig(ownerDSN)
cfg.ConnConfig.RuntimeParams = map[string]string{"statement_timeout": "10000"} // ms
pool, _ := pgxpool.NewWithConfig(ctx, cfg)
```
