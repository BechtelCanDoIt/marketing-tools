# ADR-044: Run on PostgreSQL 15 or later; uuidv7() and RETURNING old.* no longer need 18

- **Status:** Accepted (2026-11-02)
- **Date:** 2026-11-02
- **Source:** applying V002 to staging failed with `function uuidv7() does not exist`; the staging server is PostgreSQL 17.11
- **Related:** ADR-002 (daily token partitions), ADR-005 (`uuidv7()` keys), ADR-043 (one login, no roles)

## Context

The data model was designed for PostgreSQL 18 and the plan said "if 18 isn't offered, stop". It used two features that exist only there: the native `uuidv7()` (column defaults in V002-V008) and `RETURNING old.*` (six repository updates that put the previous values in the audit row). The shared staging database runs 17.11, and we don't choose the server version.

## Decision

1. **Support PostgreSQL 15 and later.** 15 is the floor because the `*_v` views use `security_invoker`. The runner refuses an older server.
2. **`uuidv7()` is installed by V001 when the server lacks it.** V001 creates `uuidv7()` in the Amplify schema (a v4 uuid with the Unix time in milliseconds in the first 48 bits and the version bits set to 7) only when the server has no native `pg_catalog.uuidv7()`, so on 18 it does nothing. It is in V001, the first script, because V002 onward use it as a column default, and so it also works when the scripts are applied by hand without the runner. The schema must be first on the `search_path` (the runner does that).
3. **`RETURNING old.*` becomes a data-modifying CTE.** `WITH prev AS (SELECT … FOR UPDATE) UPDATE … FROM prev … RETURNING prev.old_…`. The row is read and locked in the same statement that changes it, so the version check and the audit "before" values stay atomic. Applied in the campaign, connection, sharing, scoring, external sharing and settings repositories.
4. **Local and CI match staging.** Compose and the test scripts pin `postgres:17.11`, the version staging runs, so local work never uses a newer server than we deploy to. CI runs the database integration tests on 15, 17 and 18: the floor, staging's version and the newest.

## Consequences

- Staging (17.11) and any 15-17 server work with the same scripts. Nothing needs the DBA beyond the user, the schema and the two extensions (ADR-043).
- **The compatible `uuidv7()` is not monotonic inside one millisecond.** The native one adds a sub-millisecond counter; this one fills the rest with random bits. Ids made in different milliseconds still sort by creation, which is all `ORDER BY id` and the index locality rely on. Nothing in Amplify orders by id within a millisecond.
- Each table binds the function by OID when its default is created, so upgrading a server from 17 to 18 leaves existing tables working; new databases there use the native one.
- A new PostgreSQL 16+ or 17+ feature in a script or query now needs a check against the floor (15). The CI matrix is the guard.

## Links

- [V001__schema_and_extensions.sql](../../amplify-database/migrations/V001__schema_and_extensions.sql)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md)
