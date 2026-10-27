# Runbook: deploy Amplify to Choreo (plan M8b)

Console steps that config-as-code can't do. The repo side is done: Dockerfiles, `.choreo/component.yaml` (schemaVersion 1.2) per component, `workload.yaml` for OpenChoreo, and `projects/marketing-tools/apps/amplify/scripts/check-descriptors.sh` to catch drift. Run the check before every Choreo change.

Owner: a WSO2 Digital org admin in Choreo. Order matters: database first, then Jobs and Scheduler, then Backend (its connections point at them), then the API Proxy.

## A. Org, repo, project

1. **A1 Bring Your Own Repository.** Choreo console > Organization settings > GitHub: authorize the Choreo GitHub app on the WSO2-managed org and grant it the **marketing-tools** repo only (not "all repositories"). Amplify lives there at `apps/amplify` (ADR-033), so every build path in the table below is relative to the marketing-tools repo root.
2. **A2 Project.** Create project **Amplify** in the WSO2 Digital org. Environments: **dev** and **prod** (add staging only if the org standard requires it).
3. **A3 Cost check.** Before creating paid resources, price the pilot (~830 employees): 3 services + 1 manual task + 1 dev-only mock, 1 replica each, 2 Postgres databases per environment (Amplify, scheduler) on a plan **with backups**. Record the estimate in the plan (M8b "Cost check").

## B. Databases (per environment)

1. **B1** Create a Choreo-managed PostgreSQL **18** server per environment (dev, prod) on a paid plan with backups (Hobbyist has none). If 18 isn't offered, stop: M3 depends on native `uuidv7()` (fallback: UUIDv7 generated in Ballerina, never v4).
   - **B1a Extension check (plan D2).** On each new server run `apps/amplify/amplify-database/checks/d2_extensions.sql` (marketing-tools repo): it lists `pg_partman`, `pg_cron`, `pgaudit`, `citext`, `pg_trgm` and `SELECT version()`. Record the output in the plan's D2 line. `citext` and `pg_trgm` are required; if either is missing, stop and raise it (B18) before running DB Migrate.
2. **B2** Database `amplify`; bootstrap admin credentials go only into the DB Migrate component's secrets (C5).
3. **B3** Database `scheduler` with its own user (ADR-026). Never Amplify's users.
4. **B4** Record backup frequency and retention; restore one backup into dev once (plan M3 "Backups").

## C. Components (all: **Create > Bring your own repo > Dockerfile** build preset, branch `main`)

The Docker context is where Choreo reads `.choreo/component.yaml`, so each component has its own (ADR-027). Use these values exactly:

| Component (display name) | Type | Component directory / Docker context | Dockerfile path |
|---|---|---|---|
| Amplify Jobs | Service | `apps/amplify` | `apps/amplify/amplify-jobs/Dockerfile` |
| Amplify Scheduler | Service | `apps/amplify/amplify-scheduler` | `apps/amplify/amplify-scheduler/Dockerfile` |
| Amplify DB Migrate | Manual Task | `apps/amplify/amplify-database` | `apps/amplify/amplify-database/Dockerfile` |
| Amplify Backend | Service | `apps/amplify` | `apps/amplify/amplify-api/Dockerfile` |
| LinkedIn Mock (dev only) | Service | `apps/amplify/linkedin/apps/mock_linkedin` | `apps/amplify/linkedin/apps/mock_linkedin/Dockerfile` |

After each build, confirm the endpoint Choreo shows matches the descriptor (name, port, visibility). If Choreo shows the wrong port, the Docker context is wrong.

1. **C1 Amplify DB Migrate** (Manual Task). Config form: `BAL_CONFIG_VAR_DBHOST/DBPORT/DBNAME/DBUSER` from B1/B2, secrets `BAL_CONFIG_VAR_DBPASSWORD` (bootstrap admin), `APIDBPASSWORD`, `JOBSDBPASSWORD`, `READONLYDBPASSWORD` (generate, 16+ chars, store only in Choreo). Run it once per environment, then after every release that adds a `V###`/`S###` script. Check the log ends with `Migration run done`.
2. **C2 Amplify Jobs** (Project visibility only). DB: user `amplify_jobs` + its password. `TOKENKEYS` (`keyId:base64Key`, `openssl rand -base64 32`, one per environment, never shared dev↔prod) + `TOKENCURRENTKEYID`. Chat: `CHATWEBHOOKURL` secret (dev = test space, prod = WSO2 Club; see `google-chat-webhook.md`), `CHATSPACE` (`dev-test` / `club`), `CHATCARDAVATARURL` and `CHATDEFAULTIMAGEURL` (both optional; the default image is a public HTTPS PNG/JPEG pinned to a commit, see `google-chat-webhook.md` section C), `SHAREPAGEBASEURL` (the One WSO2 Celebrate page, e.g. `https://one.wso2.com/amplify/celebrate`; the card button adds `?share=<campaignId>`). LinkedIn: dev = LinkedIn Mock URLs + mock client id; prod = `https://api.linkedin.com`, `https://www.linkedin.com` + prod app client id. **Never** set `CHATALLOWINSECUREHTTP`.
3. **C3 Amplify Scheduler** (Project visibility only, no auth upstream, never published, never behind the proxy). Secret `DSN` = `postgres://<user>:<pw>@<host>:<port>/scheduler?sslmode=require` (B3).
4. **C4 Connections from Amplify Backend.** Backend > Connections > create `amplify-jobs` (to Amplify Jobs, Project) and `amplify-scheduler` (to Amplify Scheduler, Project). Open each connection's developer guide and copy its `resourceRef` into `apps/amplify/.choreo/component.yaml` (marketing-tools repo) (replace `REPLACE_WITH_ID`), commit, push. Both `BAL_CONFIG_VAR_JOBSURL` and `BAL_CONFIG_VAR_SCHEDULERJOBSURL` read the jobs connection's `ServiceURL`.
5. **C5 Amplify Backend** (endpoint `Project`, schema `amplify-api/openapi.yaml`). `ENVIRONMENT` = `dev` or `prod` (**never `local`**; that and `DEVLOCALJWTENABLED` stay unset, ADR-023). `GATEWAYJWKSURL` / `GATEWAYISSUER` / `GATEWAYAUDIENCES` from the Choreo gateway's backend JWT (identity-setup runbook). DB user `amplify_api`. LinkedIn client id/secret (secret), redirect URI = the One WSO2 callback page for that environment. Same `TOKENKEYS` as Jobs in that environment. Team rosters: `PEOPLEDIRECTORYURL`, `PEOPLEDIRECTORYTOKENURL`, `PEOPLEDIRECTORYCLIENTID` and `PEOPLEDIRECTORYCLIENTSECRET` (secret) from the people-app connection (C7). Left empty, My Team answers `UNAVAILABLE` and the rest works.
6. **C6 LinkedIn Mock** (dev only; never promote to prod). Endpoints: api `Project`, www `Public` (the browser follows the OAuth redirect). `CLIENTID`/`CLIENTSECRET` = made-up values matching Backend/Jobs in dev, `WWWBASEURL` = the www endpoint's public URL, `BAL_CONFIG_DATA` = `redirectUris = ["<dev One WSO2 callback>"]`. In dev, Backend `LINKEDINAUTHBASEURL` = the mock's **public** www URL (the authorization URL is shown to the browser).

7. **C7 People directory connection** (team rosters, ADR-019). Needs the people-app service-client change merged and deployed first (people-ops-suite PR).
   1. Amplify Backend > Connections > create a connection to the **people-app** API (another project, so Organization visibility). It issues OAuth2 client credentials; note the client id, secret and token URL.
   2. Call people-app through it once with those credentials and decode the `x-jwt-assertion` people-app receives (people-app logs, or a temporary echo). **Confirm two claims:** which one carries the client id (people-app default `azp`), and which one marks the token as issued to an application, with its value (default `aut` = `APPLICATION`). If they differ, people-app's `clientIdClaim`, `applicationClaim` and `applicationValue` must change to match (threat model AMP-R5).
   3. People-app team, per environment: add the client id to `[people.authorization.serviceClients] directoryClientIds` and redeploy people-app. Only `GET /employees/basic-info` opens to it.
   4. Set C5's `PEOPLEDIRECTORYURL` (the connection's service URL + `/employees/basic-info`), `PEOPLEDIRECTORYTOKENURL`, `PEOPLEDIRECTORYCLIENTID` and `PEOPLEDIRECTORYCLIENTSECRET` (secret). Redeploy the Backend.
   5. Check: `GET /leaderboard` as an employee shows `teamStatus: OK` and their sub-team. A 500 from people-app means the client id isn't listed or the claim is wrong; a 403 means the route isn't the directory.

## D. API Proxy (console only)

1. **D1 Spike first:** create an API Proxy targeting Amplify Backend's Project endpoint. If Choreo refuses a Project-visible target, set the Backend endpoint to `Organization` in `.choreo/component.yaml` and record it in an ADR (the proxy stays the only *published* API, ADR-004).
2. **D2** Import `amplify-api/openapi.yaml`; access mode as One WSO2 needs (External if the SPA calls it from the browser). Key manager: Asgardeo (identity-setup runbook A3–A6). Per-resource scopes from the `x-roles` in the spec; rate limits per resource (shares, external shares tighter than reads).
3. **D3** Turn on backend JWT so the Backend gets `x-jwt-assertion`; copy its JWKS/issuer/audience into C5.
4. **D4** Security headers at the proxy too if supported (`nosniff`, CSP `upgrade-insecure-requests`, HSTS).
5. **D5 WAF / egress.** If the org uses egress control, allow-list only `api.linkedin.com`, `www.linkedin.com`, `chat.googleapis.com` and the people-app connection's gateway host for this project. Attach the org WAF policy to the proxy if one exists.

## E. Versioning and promotion

1. **E1** First version **v1.0.0 from `main`**; no extra deployment tracks.
2. **E2** Build once, promote the same image dev → prod. Only config and secrets differ per environment.
3. **E3** Before promoting: run DB Migrate in prod, then deploy Jobs, Scheduler, Backend; check Backend `GET /ready` (via the proxy test console) and that the startup log says `Scheduler sync … SYNCED`.

## F. Observability

Alerts (Choreo logs/metrics): outbox `FAILED`, share failure rate, breaker `OPEN` in the run log, 5xx rate, scheduler job failures (scheduler `/jobs/{id}/history`, Project network only), `schedulerSync: PENDING` / reconcile give-up log, partition-maintenance failures.

## Go-live config review (M10)

No environment has `BAL_CONFIG_VAR_ENVIRONMENT=local`, `DEVLOCALJWTENABLED`, `CHATALLOWINSECUREHTTP` or a LinkedIn Mock URL in prod. `scripts/check-descriptors.sh` passes.
