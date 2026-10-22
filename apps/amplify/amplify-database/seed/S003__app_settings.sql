-- Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
--
-- WSO2 LLC. licenses this file to you under the Apache License,
-- Version 2.0 (the "License"); you may not use this file except
-- in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.

-- S003: app_setting defaults (phase1-data-model › infrastructure, leaderboards.md, po-dashboard.md).
-- Existing values are never overwritten: an admin's change survives a re-seed.

SET LOCAL ROLE amplify_migrate;

INSERT INTO config.app_setting (key, value)
VALUES ('leaderboard.top_n', '3'),                  -- B16
       ('team.visibility', '"TEAM"'),               -- ADR-019: TEAM or COMPANY
       ('campaign.default_window_days', '30'),      -- C7
       ('po.review_sla_hours', '48'),               -- po-dashboard.md
       ('posts.window_days', '14'),
       ('connection.reminder_days', '7'),
       ('connection.token_grace_days', '5'),        -- ADR-002, D7 open
       ('audit.retention_months', '60'),            -- B17
       ('sharing.enabled', 'true'),                 -- kill switch
       ('announcements.enabled', 'true'),           -- kill switch
       -- Scorecard targets: starting lines for PO to tune, not agreed numbers.
       ('scorecard.target_connected_pct', '25'),    -- employees connected, % of headcount
       ('scorecard.max_expired_pct', '5'),          -- expired connections, % of connected (ceiling)
       ('scorecard.target_share_success_pct', '98'),
       ('scorecard.target_priority_reach_pct', '25'), -- priority post reposted by this % of connected
       ('scorecard.target_active_30d', '100'),      -- people with activity in the last 30 days
       ('scorecard.target_reposts_per_week', '150')
ON CONFLICT (key) DO NOTHING;
