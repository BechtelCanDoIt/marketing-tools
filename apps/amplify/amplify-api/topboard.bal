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


// The Celebrate "Top three amplifiers" board. Company wide (never narrowed to a team): the weekly top N is
// summed from the points ledger for the current calendar week (Monday 00:00 UTC to the next Monday) and kept
// in memory for `topBoardCacheSeconds` (default 2 hours). The first caller after it runs out loads the
// totals; everyone else reuses them. The viewer's own line ("My position") comes from the same cached
// totals, so it matches the top three. `leaderboard.top_scope = ALL` serves the all-time standings instead.

import amplify_api.auth;
import amplify_domain.recognition;

import ballerina/http;
import ballerina/log;
import ballerina/time;

# How long the weekly totals are reused, seconds (2 hours). 0 = read every time.
configurable decimal topBoardCacheSeconds = 7200;

# `Cache-Control` of the top board: the body holds the viewer's own position, so it is private.
const string TOP_BOARD_CACHE = "private, max-age=60";

# Weekly points per employee as of `loadedAt`.
type WeeklyTotals record {|
    # Monday 00:00 UTC the totals are for
    time:Utc weekStart;
    # One total per employee with points that week
    recognition:EmployeeTotal[] totals;
    # When the totals were read
    time:Utc loadedAt;
    # Monotonic time of the read, for the lifetime check
    decimal readAt;
|};

isolated WeeklyTotals? weeklyCache = ();

# Entries in the weekly cache (0 or 1; test seam).
#
# + return - Cached entries
isolated function weeklyCacheSize() returns int {
    lock {
        return weeklyCache is () ? 0 : 1;
    }
}

# Empties the weekly cache (test seam).
isolated function dropWeeklyCache() {
    lock {
        weeklyCache = ();
    }
}

# The weekly totals for the week holding `now`: the cached copy while it is fresh and from the same week,
# else a new read. A failed read falls back to an older copy of the same week rather than failing the
# Celebrate page; with none it returns the error.
#
# + now - Current time
# + return - Totals, or an error when none can be had
isolated function weeklyTotals(time:Utc now) returns WeeklyTotals|error {
    time:Utc weekStart = recognition:weekStartOf(now);
    decimal mono = time:monotonicNow();
    WeeklyTotals? stale = ();
    lock {
        WeeklyTotals? hit = weeklyCache;
        if hit is WeeklyTotals && hit.weekStart == weekStart {
            if mono - hit.readAt < topBoardCacheSeconds {
                return hit.clone();
            }
            stale = hit.clone();
        }
    }
    recognition:EmployeeTotal[]|error totals = weeklyTotalsRead(weekStart);
    if totals is error {
        if stale is WeeklyTotals {
            log:printWarn("Weekly top board read failed, serving the previous totals", reason = totals.message());
            return stale;
        }
        return totals;
    }
    WeeklyTotals fresh = {weekStart, totals, loadedAt: now, readAt: mono};
    lock {
        weeklyCache = fresh.clone();
    }
    return fresh;
}

# One viewer's Celebrate board: the company top N and their own line, for the configured scope.
#
# + p - Caller
# + correlationId - Request correlation id
# + return - The board, or problem details
isolated function topBoard(auth:Principal p, string? correlationId) returns http:Response|ProblemResponse {
    do {
        Settings settings = check loadSettings();
        int topN = settings.topN;
        time:Utc now = time:utcNow();
        recognition:Standing[] top;
        recognition:Standing? mine;
        map<json> scopeInfo;
        if settings.topScope == "WEEK" {
            WeeklyTotals week = check weeklyTotals(now);
            recognition:Standing[] ranked = recognition:rankStandings("WEEK", week.totals, {}, topN);
            top = recognition:topN(ranked, topN);
            recognition:Standing[] own = from recognition:Standing s in ranked
                where s.employeeId == p.employeeId
                select s;
            mine = own.length() > 0 ? own[0] : ();
            scopeInfo = {
                period: "WEEK",
                weekStart: ts(week.weekStart),
                weekEnd: ts(time:utcAddSeconds(week.weekStart, 7d * 86400d)),
                generatedAt: ts(week.loadedAt)
            };
        } else {
            top = check topStandings("ALL", topN);
            mine = check standingOf(p.employeeId, "ALL");
            scopeInfo = {period: "ALL", weekStart: (), weekEnd: (), generatedAt: ts(now)};
        }
        scopeInfo["topN"] = topN;
        scopeInfo["company"] = from recognition:Standing s in top
            select {employeeId: s.employeeId, displayName: s.displayName, email: s.email,
                points: s.totalPoints, rank: s.rank, previousRank: s.previousRank};
        scopeInfo["me"] = personal(p.employeeId, mine, topN).toJson();
        http:Response res = check jsonBody(scopeInfo);
        cacheable(res, TOP_BOARD_CACHE);
        return res;
    } on fail error e {
        return failure(e, correlationId, "Top amplifiers");
    }
}
