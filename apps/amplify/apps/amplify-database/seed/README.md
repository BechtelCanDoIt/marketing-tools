# Seed

Reference data applied after the migrations, tracked in `public.schema_version` like them (`S###__name.sql`).
Every insert is `ON CONFLICT DO NOTHING`, so an admin's later change is never overwritten.

- `S001__point_rules.sql`: REPOST 5, REPOST_COMMENTARY 12, SHARE 5, SHARE_COMMENTARY 12, OWN_POST 20,
  OWN_POST_AMPLIFIED 40 (proposal `docs/proposals/point-values.md`, awaiting PO, D6).
- `S002__categories.sql`: placeholder categories until Marketing confirms them.
- `S003__app_settings.sql`: `leaderboard.top_n = 3`, `team.visibility = TEAM`, `campaign.default_window_days = 30`,
  `po.review_sla_hours = 48`, `posts.window_days = 14`, `connection.reminder_days = 7`,
  `connection.token_grace_days = 5`, `audit.retention_months = 60`, kill switches `sharing.enabled`,
  `announcements.enabled`.
- `S004__scheduler_settings.sql`: `run.schedule = @every 5m`, `run.enabled = true`,
  `maintenance.schedule = 0 2 * * *` (UTC), pushed to the scheduler by amplify-api (ADR-026).
