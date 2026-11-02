# Database migrations and integration tests

Schema source of truth: `architecture/solution/Phase 1/phase1-data-model.md`. Scripts:
`amplify-database/migrations/` (V001–V020) and `seed/` (S001–S010). Per-migration notes:
`2026-10-17-v012-recognition-lock-maintenance-timeout.md`, `2026-10-17-v013-idle-timeout-dashboard-indexes.md`,
`2026-10-27-v014-point-actions-all-phases.md`. Runner: `amplify-database/main.bal`.

## Running the migrate runner

The runner connects as the **one login user** the DBA gave Amplify (staging `amplify_stg_user`, production its own
name, local `amplify_local_user`) and works in the schema named after it (ADR-043). There are no database roles:
the login owns every object. Before the first run the DBA creates the login, the schema and the two extensions; run
`amplify-database/checks/d3_single_user.sql` to see what is missing. Configurables (Choreo: secrets / env
`BAL_CONFIG_VAR_*`):

| Key | Meaning |
| --- | --- |
| `dbHost`, `dbPort`, `dbName`, `dbUser`, `dbSslMode` | Connection (`dbSslMode` defaults to `VERIFY_FULL`; `DISABLE` only locally) |
| `dbSchema` | Schema every table lives in. Empty = the login user's name |
| `dbSslRootCert` | Managed Postgres CA PEM path (Choreo file mount, `BAL_CONFIG_VAR_DBSSLROOTCERT`, per environment). The runner warns at start-up when a remote server isn't verified |
| `dbPassword` | Login password (secret) |
| `migrationsDir`, `seedDir`, `dryRun` | Folders, and report-only mode (see below) |

No role passwords exist and no script switches role. The services take the schema from `dbSchema` at connect
(`store:newClient`).

Each script runs in its own transaction under a transaction-level advisory lock, and is recorded in
`schema_version` with a SHA-256 checksum. A rerun applies nothing; a changed applied script stops the run.
A pending script that sorts below an already-applied version also stops the run: scripts apply in version
order only, so a late-arriving `V0NN` must be renumbered above the highest applied version.

`dryRun = true` connects to the database but creates nothing (not even `schema_version`) and runs no
script. It logs each script as `pending`, `applied` or `changed` and fails when any is `changed`, so it doubles
as a checksum check before a deploy. Nothing in the database is touched.

Local: `make up` runs it once before api/jobs start; `make seed` reruns it (compose and the tests pin `postgres:17.11`, the version staging runs; CI also runs 15 and 18). Before PostgreSQL 18 the runner installs `bootstrap/uuidv7_compat.sql` first (ADR-044).

## Integration tests (PostgreSQL 15 or later)

`bal test` without a database passes: the `integration` group returns early unless enabled.

```sh
docker run -d --name amplify-pg17 -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:17.11

# 1. Runner: drops/creates `amplify_it`, plays the DBA (login user `amplify_it_user`, its schema), migrates fresh as that
#    login, reruns (idempotent), checksum guard, partition tests. Steps 2 and 3 connect as the same login.
cd amplify-database
BAL_CONFIG_VAR_ITENABLED=true BAL_CONFIG_VAR_DBPORT=55432 BAL_CONFIG_VAR_ITADMINPASSWORD=postgres \
  BAL_CONFIG_VAR_DBSSLMODE=DISABLE bal test --groups integration

# 2. Repositories and the M5 API flows (integration_m5_test.bal), as amplify_api / amplify_jobs against `amplify_it`.
cd ../amplify-domain
AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55432 bal test --groups integration

# 3. The Run (M6): mock_linkedin on 19190/19191 as LinkedIn, an in-test Chat stub on 9298.
cat > /tmp/mock-it.toml <<'TOML'
[wso2.mock_linkedin]
apiPort = 19190
wwwPort = 19191
wwwBaseUrl = "http://localhost:19191"
clientId = "it-client"
clientSecret = "it-secret"
redirectUris = ["http://localhost:3000/auth/linkedin/callback"]
enableMockAdmin = true
TOML
(cd ../../linkedin/apps/mock_linkedin && BAL_CONFIG_FILES=/tmp/mock-it.toml bal run &)
cd ../amplify-jobs
AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55432 bal test --groups integration
pkill -f mock_linkedin

docker rm -f amplify-pg18
```

Step 3 registers a campaign (card to the stub, threaded `campaign-{id}`), connects through the mock OAuth
flow and seals the token into today's partition, shares, then checks publish → engagement → points →
standing, correlation ids in audit, rerun safety (no second post, card or ledger row), one run across
replicas (advisory lock), stale-lock release and the `Idempotency-Key` purge. `bal run` of the mock rewrites
its `Dependencies.toml`; revert it.

The domain tests read environment variables (`AMPLIFY_IT`, `AMPLIFY_IT_DB_HOST`, `_PORT`, `_NAME`,
`_API_PASSWORD`, `_JOBS_PASSWORD`, `_SSL`) instead of configurables: a configurable in the root test module
is "unused" in every other module's test run and fails it. Ids are fresh UUIDv7s, so step 2 can run again.

## Driver notes (learned the hard way)

- `execute` asks the driver for generated keys, which appends `RETURNING` to the statement. DDL and whole
  script files go through `call` instead.
- `time:Utc` can't be bound directly (UnsupportedOperationException): bind `CAST(${store:ts(t)} AS timestamptz)`.
- uuid and date columns need `CAST(${x} AS uuid)` / `CAST(${x} AS date)`; read them back as `::text`.
- A `?` in SQL text is a bind marker to the driver; scripts must not contain one.
