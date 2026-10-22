// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.


// Settings the resources depend on (`config.app_setting`), typed with defaults, and the rules for the
// admin `PUT /admin/settings`: only known keys, values in range. Coin settings (`coin.*`) stay hidden in
// phase 1.

import amplify_api.scheduler;
import amplify_domain.store;

import ballerina/time;

# Typed view of the settings the API uses.
type Settings record {|
    # `leaderboard.top_n` (B16)
    int topN = 3;
    # `team.visibility`: `TEAM` or `COMPANY` (ADR-019)
    string teamVisibility = "TEAM";
    # `campaign.default_window_days` (C7)
    int defaultWindowDays = 30;
    # `po.review_sla_hours`
    int reviewSlaHours = 48;
    # `posts.window_days`
    int postsWindowDays = 14;
    # `connection.reminder_days`
    int reminderDays = 7;
    # `scorecard.target_connected_pct`: employees connected, % of headcount
    int targetConnectedPct = 25;
    # `scorecard.max_expired_pct`: expired connections, % of connected (a ceiling)
    int maxExpiredPct = 5;
    # `scorecard.target_share_success_pct`
    int targetShareSuccessPct = 98;
    # `scorecard.target_priority_reach_pct`: a post counts as reaching people at this % of connected
    int targetPriorityReachPct = 25;
    # `scorecard.target_active_30d`: people with an engagement in 30 days
    int targetActive30d = 100;
    # `scorecard.target_reposts_per_week`
    int targetRepostsPerWeek = 150;
    # `sharing.enabled` kill switch
    boolean sharingEnabled = true;
    # `announcements.enabled` kill switch
    boolean announcementsEnabled = true;
    # `run.schedule`: when the scheduler calls amplify-jobs `POST /runs` (ADR-026)
    string runSchedule = "@every 5m";
    # `run.enabled`: false disables the scheduler's run job
    boolean runEnabled = true;
    # `maintenance.schedule`: when the scheduler calls `POST /maintenance/partitions`
    string maintenanceSchedule = "0 2 * * *";
|};

# One editable key: its kind and allowed range.
type SettingRule record {|
    # `int`, `boolean`, `enum` or `schedule` (scheduler format, ADR-026)
    "int"|"boolean"|"enum"|"schedule" kind;
    # Smallest int; for `schedule`, the shortest `@every` interval in seconds
    int min = 0;
    # Largest int
    int max = 0;
    # Allowed strings for `enum`
    string[] values = [];
|};

final readonly & map<SettingRule> EDITABLE_SETTINGS = {
    [SETTING_TOP_N]: {kind: "int", min: 1, max: 50},
    [SETTING_TEAM_VISIBILITY]: {kind: "enum", values: ["TEAM", "COMPANY"]},
    [SETTING_WINDOW_DAYS]: {kind: "int", min: 1, max: 365},
    [SETTING_SLA_HOURS]: {kind: "int", min: 1, max: 720},
    [SETTING_POSTS_WINDOW]: {kind: "int", min: 1, max: 365},
    [SETTING_REMINDER_DAYS]: {kind: "int", min: 1, max: 30},
    [SETTING_TOKEN_GRACE_DAYS]: {kind: "int", min: 1, max: 30},
    [SETTING_AUDIT_RETENTION]: {kind: "int", min: 60, max: 120},
    [SETTING_SHARING_ENABLED]: {kind: "boolean"},
    [SETTING_ANNOUNCEMENTS_ENABLED]: {kind: "boolean"},
    [SETTING_TARGET_CONNECTED_PCT]: {kind: "int", min: 1, max: 100},
    [SETTING_MAX_EXPIRED_PCT]: {kind: "int", min: 0, max: 100},
    [SETTING_TARGET_SHARE_SUCCESS_PCT]: {kind: "int", min: 1, max: 100},
    [SETTING_TARGET_PRIORITY_REACH_PCT]: {kind: "int", min: 1, max: 100},
    [SETTING_TARGET_ACTIVE_30D]: {kind: "int", min: 1, max: 100000},
    [SETTING_TARGET_REPOSTS_PER_WEEK]: {kind: "int", min: 1, max: 1000000},
    [SETTING_RUN_SCHEDULE]: {kind: "schedule", min: minRunIntervalSeconds},
    [SETTING_RUN_ENABLED]: {kind: "boolean"},
    [SETTING_MAINTENANCE_SCHEDULE]: {kind: "schedule", min: 3600}
};

# Keys whose change is pushed to the scheduler.
final readonly & string[] SCHEDULE_SETTINGS = [SETTING_RUN_SCHEDULE, SETTING_RUN_ENABLED, SETTING_MAINTENANCE_SCHEDULE];

# Whether a key is shown on the admin screen (Coin settings are hidden in phase 1).
#
# + key - Setting key
# + return - True when visible
isolated function isVisibleSetting(string key) returns boolean => !key.startsWith("coin.");

# Loads the typed settings; unknown or malformed values fall back to the defaults.
#
# + return - Settings, or an error when the database can't be read
isolated function loadSettings() returns Settings|error {
    decimal now = time:monotonicNow();
    int generation;
    lock {
        [Settings, decimal]? hit = settingsCache.entry;
        if hit is [Settings, decimal] && now - hit[1] < settingsCacheSeconds {
            return hit[0].clone();
        }
        generation = settingsCache.generation;
    }
    Settings fresh = check freshSettings();
    cacheSettings(fresh, now, generation);
    return fresh;
}

# Reads the settings from the database, skipping the cache. SchedulerSync uses it: it must push what was
# committed, not what a reader cached a moment before the commit.
#
# + return - Settings, or an error when the database can't be read
isolated function freshSettings() returns Settings|error => settingsOf(check settingRows());

# Caches settings read under `generation`, unless a save on this replica bumped it meanwhile: rows read
# before that commit must not land in the cache after `forgetSettings` cleared it.
#
# + settings - Settings read
# + readAt - Monotonic time of the read
# + generation - Cache generation when the read started
isolated function cacheSettings(Settings settings, decimal readAt, int generation) {
    lock {
        if generation == settingsCache.generation {
            settingsCache.entry = [settings.clone(), readAt];
        }
    }
}

# Drops the cached settings (after this replica saves a change).
isolated function forgetSettings() {
    lock {
        settingsCache.entry = ();
        settingsCache.generation += 1;
    }
}

# Settings cache lifetime, seconds (M11 load test: one settings query per request was a quarter of the
# read path). Other replicas see a change, kill switches included, within this time. 0 = no cache.
configurable decimal settingsCacheSeconds = 5;

# The settings cache: the entry and a generation every `forgetSettings` bumps.
type SettingsCache record {|
    # Settings and the monotonic time they were read
    [Settings, decimal]? entry;
    # Bumped by every local save
    int generation;
|};

isolated SettingsCache settingsCache = {entry: (), generation: 0};

# Typed settings from rows.
#
# + rows - Rows
# + return - Settings
isolated function settingsOf(store:Setting[] rows) returns Settings {
    Settings s = {};
    foreach store:Setting row in rows {
        json v = row.value;
        match row.key {
            SETTING_TOP_N => {
                s.topN = v is int && v > 0 ? v : s.topN;
            }
            SETTING_TEAM_VISIBILITY => {
                s.teamVisibility = v == "COMPANY" ? "COMPANY" : "TEAM";
            }
            SETTING_WINDOW_DAYS => {
                s.defaultWindowDays = v is int && v > 0 ? v : s.defaultWindowDays;
            }
            SETTING_SLA_HOURS => {
                s.reviewSlaHours = v is int && v > 0 ? v : s.reviewSlaHours;
            }
            SETTING_POSTS_WINDOW => {
                s.postsWindowDays = v is int && v > 0 ? v : s.postsWindowDays;
            }
            SETTING_REMINDER_DAYS => {
                s.reminderDays = v is int && v > 0 ? v : s.reminderDays;
            }
            SETTING_TARGET_CONNECTED_PCT => {
                s.targetConnectedPct = v is int && v > 0 ? v : s.targetConnectedPct;
            }
            SETTING_MAX_EXPIRED_PCT => {
                s.maxExpiredPct = v is int && v >= 0 ? v : s.maxExpiredPct;
            }
            SETTING_TARGET_SHARE_SUCCESS_PCT => {
                s.targetShareSuccessPct = v is int && v > 0 ? v : s.targetShareSuccessPct;
            }
            SETTING_TARGET_PRIORITY_REACH_PCT => {
                s.targetPriorityReachPct = v is int && v > 0 ? v : s.targetPriorityReachPct;
            }
            SETTING_TARGET_ACTIVE_30D => {
                s.targetActive30d = v is int && v > 0 ? v : s.targetActive30d;
            }
            SETTING_TARGET_REPOSTS_PER_WEEK => {
                s.targetRepostsPerWeek = v is int && v > 0 ? v : s.targetRepostsPerWeek;
            }
            SETTING_SHARING_ENABLED => {
                s.sharingEnabled = v != false;
            }
            SETTING_ANNOUNCEMENTS_ENABLED => {
                s.announcementsEnabled = v != false;
            }
            SETTING_RUN_SCHEDULE => {
                s.runSchedule = v is string && scheduler:checkSchedule(v) is () ? v : s.runSchedule;
            }
            SETTING_RUN_ENABLED => {
                s.runEnabled = v != false;
            }
            SETTING_MAINTENANCE_SCHEDULE => {
                s.maintenanceSchedule = v is string && scheduler:checkSchedule(v) is () ? v : s.maintenanceSchedule;
            }
        }
    }
    return s;
}

# Checks one admin change.
#
# + key - Key
# + value - New value
# + return - `()` when valid, else `[code, detail]`
isolated function checkSettingChange(string key, json value) returns [string, string]? {
    SettingRule? rule = EDITABLE_SETTINGS[key];
    if rule is () {
        return [UNKNOWN_SETTING, string `${key} can't be changed here`];
    }
    match rule.kind {
        "int" => {
            if value !is int || value < rule.min || value > rule.max {
                return [INVALID_SETTING, string `${key} must be a whole number from ${rule.min} to ${rule.max}`];
            }
        }
        "boolean" => {
            if value !is boolean {
                return [INVALID_SETTING, string `${key} must be true or false`];
            }
        }
        "schedule" => {
            if value !is string {
                return [INVALID_SETTING, string `${key} must be a schedule string`];
            }
            string? problemOf = scheduler:checkSchedule(value, rule.min);
            if problemOf is string {
                return [INVALID_SETTING, string `${key} ${problemOf}`];
            }
        }
        _ => {
            if value !is string || rule.values.indexOf(value) is () {
                return [INVALID_SETTING, string `${key} must be one of ${string:'join(", ", ...rule.values)}`];
            }
        }
    }
    return ();
}
