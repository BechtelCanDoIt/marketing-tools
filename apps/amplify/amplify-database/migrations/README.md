# Migrations

Forward-only, versioned: `V001__schemas_roles.sql` … `V013__idle_timeout_dashboard_indexes.sql`. Lowercase snake_case
after `__`. Never edit an applied script (the runner compares checksums and stops); add a new version.

| Script | What |
| --- | --- |
| V001 | Roles (NOLOGIN, no passwords), schemas owned by `amplify_migrate`, `citext` + `pg_trgm`, password setter |
| V002 | `identity.employee`; `campaign.category`, `campaign`, `campaign_tag`, `campaign_v` |
| V003 | `member_connection`, `provider_token` (daily partitions), `oauth_state`, `member_connection_v`, `config.int_setting` |
| V004 | `share_request`, `engagement`, `engagement_verification`, `share_request_v`, `engagement_v` |
| V005 | `external_share` (C4, C5) + `external_share_v` |
| V006 | `point_rule`, `points_ledger` (column-level settlement grant, no PAID in phase 1) |
| V007 | `standing`, `standing_version`, `employee_points_monthly`, `campaign_participation` |
| V008 | `announcement` + view, `outbox`, `idempotency_key`, `audit_log` (monthly partitions), `app_setting` |
| V009 | Partition upkeep (`SECURITY DEFINER`): create ahead, token drop rule, audit retention, outbox purge, `run_partition_maintenance()` |
| V010 | Recognition upkeep: `apply_ledger_entry`, one-UPDATE `rerank`, `rebuild` |
| V011 | `announcement.chat_thread_name` (thread Chat returned, M6a); `announcement_v` recreated |
| V012 | Recognition writers serialized (advisory lock in `apply_ledger_entry`/`rerank`/`rebuild`); upkeep functions `lock_timeout = 5s` + one upkeep at a time ([doc](../../docs/migrations/2026-10-17-v012-recognition-lock-maintenance-timeout.md)) |
| V013 | `idle_in_transaction_session_timeout = 30s` on `amplify_api`/`amplify_jobs` (ALTER ROLE as the bootstrap admin, before `SET LOCAL ROLE`); dashboard indexes `points_ledger (created_at)`, `share_request (failed_at)`; lock-order comments on the V012 recognition functions ([doc](../../docs/migrations/2026-10-17-v013-idle-timeout-dashboard-indexes.md)) |

Rules: V001 runs as the bootstrap admin; every other script runs `SET LOCAL ROLE amplify_migrate` before its DDL (V013 first alters the app roles' settings as the bootstrap admin, which `amplify_migrate` can't).
Enums are `text` + `CHECK`. No `?` anywhere in a script (the JDBC driver treats it as a bind marker).
The runner stops on a `.sql` file whose name doesn't match `V###__snake_name.sql` and on two scripts with
the same number, so a misnamed script can't be skipped without a word.
