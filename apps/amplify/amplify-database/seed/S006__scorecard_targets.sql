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


-- S006: scorecard targets (ADR-035/036). Starting lines for PO to tune, not agreed numbers; the scorecard
-- shows On track when a measure meets its line and Watch when it doesn't.
-- Existing values are never overwritten: an admin's change survives a re-seed.

SET LOCAL ROLE amplify_migrate;

INSERT INTO config.app_setting (key, value)
VALUES ('scorecard.target_connected_pct', '25'),      -- employees connected, % of headcount
       ('scorecard.max_expired_pct', '5'),            -- expired connections, % of connected (a ceiling)
       ('scorecard.target_share_success_pct', '98'),  -- published / (published + failed), 7 days
       ('scorecard.target_priority_reach_pct', '25'), -- a campaign reaches people at this % of connected
       ('scorecard.target_active_30d', '100'),        -- people with an engagement in 30 days
       ('scorecard.target_reposts_per_week', '150')   -- reposts in the last 7 days
ON CONFLICT (key) DO NOTHING;
