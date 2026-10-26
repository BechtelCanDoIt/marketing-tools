# WSO2 Amplify — Phase 1 Activity Matrix

Role × endpoint, with the CRUD verb and the state conditions the backend checks. Source: the Roles table and M5 in the [plan](../../../docs/requirements/phase1-planned-todos.md), plus ADR-010 to ADR-017 in [architecture/decisions](../../decisions/README.md). Copy this into the threat model.

Enforced twice: API proxy scopes per resource, then the Ballerina request interceptor in `amplify-api`. The backend is the real gate; the UI only hides.

**In code:** `projects/marketing-tools/apps/amplify/amplify-api/modules/auth/matrix.bal` mirrors this table row for row; change both together (ADR-022). The interceptor checks role × method × route only; routes not listed are denied. Everything in the "State conditions" column (status such as `PENDING`/`OPEN`, ownership "own" and `employeeId` = caller, PO-not-own-claim, kill switches, reasons required) is checked by the use case behind the resource, and the code row's `useCase` note says so. A missing `groups` claim means plain `EMP`.

**Roles.** `EMP` = any signed-in employee (no extra role; every other role includes it). `PO` = `amplify_po`. `MKT` = `amplify_marketing`. `SLT` = `amplify_slt`. `ADM` = `amplify_admin`. "Own" means the row's `employee_id` is the caller, taken from the token, never from the request.

**CRUD.** C create · R read · U update · D delete/archive · X action (state transition). `—` = denied (403).

**Phasing (2026-10-19).** Every row below is built and enforced. Phase 1 One WSO2 screens use only: `GET /me`, campaigns (read; PO/MKT register and edit through New Post and Current Posts), categories, LinkedIn connect, `POST /campaigns/{id}/shares`, `GET /me/shares` and `GET /leaderboard`. External shares and PO review, point rules and PO adjust/reverse are phase 3; points history, Team, the PO dashboard and reports are phase 2. Those endpoints stay reachable through the proxy with the roles shown here, so the matrix applies to them in phase 1 too.

## Matrix

| Context | Endpoint | EMP | PO | MKT | SLT | ADM | State conditions and notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Identity | `GET /me` | R own | R own | R own | R own | R own | Upserts the employee row (name, email) |
| S1 Campaign | `GET /campaigns?status=&window=&tag=&page=&size=` | R | R | R | R | R | Employees see `open` only (inside `opens_at`–`closes_at`), default window 14d |
| S1 | `GET /campaigns/{id}` | R | R | R | R | R | Employees: open campaigns only; PO/MKT see any status |
| S1 | `GET /tags`, `GET /categories` | R | R | R | R | R | |
| S1 | `POST /campaigns` | — | C | C | — | — | ADR-012. `closes_at` defaults to `opens_at` + `campaign.default_window_days` (30) |
| S1 | `POST /campaigns?shareNow=true` | — | C + X | C + X | — | — | Also calls `amplify-jobs POST /runs` (fire-and-forget behind a breaker) |
| S1 | `PATCH /campaigns/{id}` | — | U | U | — | — | Not on an archived campaign |
| S1 | `DELETE /campaigns/{id}` | — | D (archive) | D (archive) | — | — | Soft archive only; shares and points stay |
| S2 Connection | `POST /connections/linkedin/start` | C own | C own | C own | C own | C own | Issues `state`; one active connection per employee |
| S2 | `POST /connections/linkedin/complete` | U own | U own | U own | U own | U own | `state` must match, be unused and unexpired; same employee who started |
| S2 | `DELETE /connections/linkedin` | D own | D own | D own | D own | D own | Deletes the token row; points kept or reversed per plan D6 (open) |
| C1 Sharing | `POST /campaigns/{id}/shares` | C own | C own | C own | C own | C own | Campaign `open`; connection active (not `NEEDS_RECONNECT`); one per campaign per employee. After `FAILED` the same row is retried (ADR-015). `sharing.enabled` kill switch |
| C1 | `GET /me/shares` | R own | R own | R own | R own | R own | |
| S3 External Sharing | `POST /external-shares` | C own | C own | C own | C own | C own | Normalized `(evidence_url, action)` unique across everyone → `EVIDENCE_ALREADY_CLAIMED` (ADR-017); URL host allow-list |
| S3 | `GET /me/external-shares` | R own | R own | R own | R own | R own | |
| S3 | `GET /po/external-shares?status=PENDING` | — | R | — | — | — | |
| S3 | `POST /po/external-shares/{id}/approve` | — | X | — | — | — | Only while `PENDING`. Recommended: PO can't decide own claim |
| S3 | `POST /po/external-shares/{id}/reject` | — | X | — | — | — | Only while `PENDING`; reason required. Recommended: PO can't decide own claim |
| S3 | `POST /po/external-shares/{id}/amplified` | — | X | — | — | — | Only on an `APPROVED` claim (C4); once per claim |
| C2 Scoring | `GET /po/point-rules` | — | R | — | — | — | ADR-011 |
| C2 | `POST /po/point-rules` | — | C/U | — | — | — | ADR-011. Recommended: new version of a rule, past awards keep their value |
| C2 | `POST /po/points/adjustments` | — | C | — | — | — | Reason required; actor recorded; `recognition` updated in the same transaction (B12). ADR-010 |
| C2 | `POST /po/points/{reference}/reverse` | — | C (reversal row) | — | — | — | Reason required; only on an entry not already reversed; append-only ledger. ADR-010 |
| S4 Recognition | `GET /leaderboard` | R | R | R | R | R | Three views: company top N (`leaderboard.top_n` = 3), personal, My Team (ADR-014). The full company list is `/leaderboard/people` (ADR-035) |
| S4 | `GET /leaderboard/people?scope=&bu=&team=` | R | R | R | R | R | People ranked in the company, a BU or a team. Open to every employee ([ADR-035](../../decisions/ADR-035-open-leaderboards-and-employee-count.md)); `BU`/`TEAM` default to the caller's own. Needs the people directory (503 otherwise) |
| S4 | `GET /leaderboard/groups?by=TEAM\|BU&bu=` | R | R | R | R | R | Teams or BUs ranked by points, with participants and headcount. Open to every employee (ADR-035) |
| S4 | `GET /headcount` | R | R | R | R | R | Employees overall, by BU and team, from the people directory; memory cache 7 days (ADR-035) |
| S6 Dashboards | `GET /dashboards/operations`, `/campaigns`, `/participation`, `/glance`, `/scorecard` | — | R | R | R | R | Every `amplify_*` role, never a plain employee (403 `ROLE_NOT_PERMITTED`). Read-only, one 60 s snapshot ([ADR-036](../../decisions/ADR-036-dashboards-for-amplify-roles.md)) |
| S4 | `GET /me/points` | R own | R own | R own | R own | R own | Points only, no Coin value (A11) |
| S4 | `GET /team?q=&sort=&page=` | R (per ADR-014) | R | R (per ADR-014) | R (per ADR-014) | R (per ADR-014) | Returns emails for One WSO2 enrichment (ADR-009). Non-PO visibility follows the three-leaderboard rule |
| S4 | `GET /team/{employeeId}/history` | R own + team | R any | R own + team | R own + team | R own + team | Non-PO: own, or a member of the caller's team from the people-app directory (sub-team, else team; ADR-019) (anyone when `team.visibility = COMPANY`), else 403 `TEAM_SCOPE` ([leaderboards.md](leaderboards.md)). PO sees any row (needed for adjust/reverse) |
| S4 | `GET /po/dashboard` | — | R | — | — | — | Phase 1 (ADR-013); shape defined in M0c B6 |
| S4 (phase 2) | `GET /reports/participation`, `GET /reports/campaigns` | — | — | — | R | — | Phase 2; read-only DB user |
| S5 / Admin | `GET /admin/announcements?status=FAILED` | — | — | — | — | R | |
| S5 / Admin | `POST /admin/announcements/{id}/retry` | — | — | — | — | X | Only while `FAILED`; `announcements.enabled` kill switch |
| Admin | `GET /admin/settings` | — | — | — | — | R | |
| Admin | `PUT /admin/settings` | — | — | — | — | U | Kill switches, `leaderboard.top_n`, run schedule (`run.schedule`, `run.enabled`, `maintenance.schedule`, pushed to the scheduler, ADR-026), reminder days, `campaign.default_window_days`. Coin settings hidden |
| Admin | `POST /admin/scheduler/sync` | — | — | — | — | X | Converges the scheduler jobs to the settings (ADR-026) |
| Ops | `GET /health`, `GET /ready` | n/a | n/a | n/a | n/a | n/a | Not exposed through the proxy to users |
| Internal | `amplify-jobs POST /runs` | — | — | — | — | — | Project visibility only; called by the scheduler (ADR-026) and `amplify-api`, never by users |

## Rules that apply to every row

- Role comes from the access-token `groups`/`roles` claim only.
- "Own" is resolved from the token subject; any `employeeId` in a path for EMP is checked against it.
- Every write: one transaction with the aggregate row, an outbox row and an audit row (actor, role used, correlation ID).
- All POSTs take `Idempotency-Key`. A replay returns the first result, not a second action.
- Denials return 403 with a stable code and get an audit row (`outcome = DENIED`).

## Open items that change this matrix

- **Marketing adjust/remove** (plan M0 D14 sub-item): if the client says yes, add `MKT` to the two C2 point endpoints.
- **Team visibility for non-PO roles** follows ADR-014; confirm the My Team view once the One WSO2 team lookup is found (ADR-009).
- **Remove Connection points** (plan D6): keep or reverse.
