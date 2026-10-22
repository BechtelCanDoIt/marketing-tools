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

// The Celebrate top board: the weekly totals are read once and shared, and the scope setting.

import amplify_domain.recognition;

import ballerina/test;
import ballerina/time;

final time:Utc THURSDAY = checkpanic time:utcFromString("2026-10-22T16:00:00Z");

function seedWeek(time:Utc now, decimal ageSeconds) {
    lock {
        weeklyCache = {
            weekStart: recognition:weekStartOf(now),
            totals: [{employeeId: "e1", displayName: "Avery", email: "a@wso2.com", totalPoints: 9, lastActivityAt: ()}],
            loadedAt: now,
            readAt: time:monotonicNow() - ageSeconds
        };
    }
}

@test:Config
function testFreshWeeklyTotalsAreReusedWithoutAnotherRead() returns error? {
    seedWeek(THURSDAY, 60);
    WeeklyTotals first = check weeklyTotals(THURSDAY);
    WeeklyTotals second = check weeklyTotals(THURSDAY);
    test:assertEquals(first.loadedAt, THURSDAY);
    test:assertEquals(second.totals, first.totals);
    test:assertEquals(weeklyCacheSize(), 1);
    dropWeeklyCache();
}

@test:Config
function testExpiredTotalsOfTheSameWeekAreServedWhenTheReloadFails() returns error? {
    // Older than the 2 hour lifetime, and no database in this test: the previous totals carry on.
    seedWeek(THURSDAY, topBoardCacheSeconds + 1d);
    WeeklyTotals served = check weeklyTotals(THURSDAY);
    test:assertEquals(served.totals.length(), 1);
    dropWeeklyCache();
}

@test:Config
function testANewWeekNeverServesLastWeeksTotals() {
    seedWeek(THURSDAY, 60);
    time:Utc nextMonday = checkpanic time:utcFromString("2026-10-26T00:00:01Z");
    WeeklyTotals|error week = weeklyTotals(nextMonday);
    test:assertTrue(week is error, "last week's cache must not answer for the new week");
    dropWeeklyCache();
}

@test:Config
function testTopScopeSettingDefaultsToWeekAndAcceptsAll() {
    test:assertEquals(settingsOf([]).topScope, "WEEK");
    test:assertEquals(settingsOf([{key: SETTING_TOP_SCOPE, value: "ALL", updatedBy: "t", updatedAt: THURSDAY, version: 1}]).topScope, "ALL");
    test:assertEquals(settingsOf([{key: SETTING_TOP_SCOPE, value: "MONTH", updatedBy: "t", updatedAt: THURSDAY, version: 1}]).topScope, "WEEK");
    test:assertEquals(checkSettingChange(SETTING_TOP_SCOPE, "ALL"), ());
    test:assertTrue(checkSettingChange(SETTING_TOP_SCOPE, "MONTH") is [string, string]);
}
