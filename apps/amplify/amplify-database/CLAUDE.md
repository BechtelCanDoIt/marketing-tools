# CLAUDE.md — amplify-database

## Overview
Amplify DB Migrate: Choreo Manual Task / Compose one-shot. Applies `migrations/` (`V###`) then `seed/` (`S###`) in order, one transaction per script, records each in `schema_version` (checksum), exits. Rerun is a no-op; a changed applied script stops the run (forward-only). `dryRun = true` only lists.

## Layout
`main.bal` (runner) · `migrations/` (`V###__snake_name.sql`) · `seed/` (`S###__snake_name.sql`, idempotent `ON CONFLICT DO NOTHING`) · `checks/` (one-off checks such as `d2_extensions.sql`) · `tests/` (unit + `integration` group).

## Commands
`bal build` · `bal test` · `bal run` (from this folder). Integration tests against Postgres 18: see `docs/migrations/README.md`.

## DB connections
Connects as the one login user the DBA gave Amplify (`dbUser`, staging `amplify_stg_user`, local `amplify_local_user`) and puts its schema (`dbSchema`, default the user name) first on the `search_path`; scripts name no schema. V001 checks that the four NOLOGIN roles exist and are grantable to the login (`GRANT <role> TO <login> WITH SET TRUE`), then every later script runs `SET LOCAL ROLE amplify_migrate`, so `amplify_migrate` owns every object. No role passwords anywhere: the roles stay NOLOGIN and the services `SET ROLE` at connect through the JDBC `options` startup parameter (`dbRole`, ADR-042). `checks/d3_single_user_roles.sql` lists what the DBA still has to do. Secret: `dbPassword`. Pool of one connection (the schema is set on the session). TLS: `dbSslMode` defaults to `VERIFY_FULL` with `dbSslRootCert` (CA PEM path, Choreo file mount via `BAL_CONFIG_VAR_DBSSLROOTCERT`), same as api/jobs; start-up warns when a remote host isn't verified; Compose and the IT set `DISABLE`.

## Key patterns
Never edit an applied migration. Every `.sql` carries the Apache-2.0 header. No `?` in scripts (the JDBC driver reads it as a bind marker). Enums are `text` + `CHECK`. Views are `security_invoker`. Maintenance functions are `SECURITY DEFINER` with `SET search_path FROM CURRENT` (the runner's schema list) and `format(%I)`. Tables are `<context>_<name>`; unnamed constraints and indexes inherit that prefix, so a later script that drops one uses the prefixed name.
