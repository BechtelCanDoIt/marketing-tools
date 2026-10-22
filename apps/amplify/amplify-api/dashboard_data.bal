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


// What the dashboards read from the database (ADR-036): one snapshot of every aggregate, taken in one
// transaction and kept for 60 seconds, plus two small per-request reads. Each loader is a test seam.

import amplify_domain.recognition;
import amplify_domain.reporting;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Everything the five boards need, as of one moment.
type Snapshot record {|
    # When it was taken
    time:Utc asOf;
    # Campaigns open now
    reporting:LiveCounts live;
    # Reposts in the last 7 days
    int reposts7d;
    # Of those, with the employee's own commentary
    int reposts7dWithCommentary;
    # Reposts in the 7 days before that
    int repostsPrev7d;
    # Reposts this calendar month (UTC)
    int repostsThisMonth;
    # Reposts last calendar month
    int repostsPrevMonth;
    # Last eight weeks, oldest first
    reporting:WeekCount[] weekly;
    # Connections by state
    reporting:ConnectionBreakdown connections;
    # The funnel
    reporting:ParticipationCounts participation;
    # Points awarded this week, month and year (UTC calendar)
    reporting:PointsAwarded points;
    # People with points
    int peopleWithPoints;
    # Open campaigns and campaigns opened in the last 90 days, priority first then newest (at most 200)
    reporting:CampaignRow[] campaigns;
    # Announcement delivery by campaign id
    map<reporting:Delivery> delivery;
    # Shares in the last 7 days
    sharing:ShareHealth shares;
    # Cards for campaigns opened in the last 30 days
    reporting:CardCounts cards;
|};

# How long a snapshot is reused, seconds.
const decimal SNAPSHOT_SECONDS = 60;

isolated [Snapshot & readonly, decimal]? snapshotCache = ();

# The snapshot: cached for 60 seconds, so a refresh storm costs one set of queries.
#
# + return - The snapshot, or an error
isolated function snapshot() returns Snapshot & readonly|error {
    decimal mono = time:monotonicNow();
    lock {
        [Snapshot & readonly, decimal]? hit = snapshotCache;
        if hit is [Snapshot & readonly, decimal] && mono - hit[1] < SNAPSHOT_SECONDS {
            return hit[0];
        }
    }
    Snapshot & readonly fresh = (check loadSnapshot(time:utcNow())).cloneReadOnly();
    lock {
        snapshotCache = [fresh, mono];
    }
    return fresh;
}

# Number of cached snapshots (0 or 1), a test seam.
#
# + return - 1 when a snapshot is cached
isolated function snapshotCacheSize() returns int {
    lock {
        return snapshotCache is () ? 0 : 1;
    }
}

# Reads the snapshot in one gated transaction (R-13), so the numbers agree with each other.
#
# + now - Current time
# + return - The snapshot, or an error
isolated function loadSnapshot(time:Utc now) returns Snapshot|error {
    final postgresql:Client pg = check db();
    final readonly & time:Utc at = now.cloneReadOnly();
    return (check store:inTransactionValue(() => snapshotTx(pg, at))).ensureType();
}

isolated function snapshotTx(postgresql:Client pg, time:Utc now) returns Snapshot|error {
    Snapshot? result = ();
    string today = time:utcToString(now);
    string month = today.substring(0, 7);
    time:Utc monthStart = check time:utcFromString(month + "-01T00:00:00Z");
    time:Utc prevMonthStart = check time:utcFromString(previousMonth(month) + "-01T00:00:00Z");
    time:Utc soon = time:utcAddSeconds(now, 60);
    time:Utc weekAgo = time:utcAddSeconds(now, -7d * 86400d);
    time:Utc twoWeeksAgo = time:utcAddSeconds(now, -14d * 86400d);
    transaction {
        reporting:CampaignRow[] campaigns = check reporting:campaignRows(pg, 90, 200, now);
        string[] ids = from reporting:CampaignRow p in campaigns
            select p.campaignId;
        result = {
            asOf: now,
            live: check reporting:liveCounts(pg),
            reposts7d: check reporting:repostsBetween(pg, weekAgo, soon),
            reposts7dWithCommentary: check reporting:commentaryRepostsBetween(pg, weekAgo, soon),
            repostsPrev7d: check reporting:repostsBetween(pg, twoWeeksAgo, weekAgo),
            repostsThisMonth: check reporting:repostsBetween(pg, monthStart, soon),
            repostsPrevMonth: check reporting:repostsBetween(pg, prevMonthStart, monthStart),
            weekly: check reporting:weeklyReposts(pg, 8),
            connections: check reporting:connectionBreakdown(pg),
            participation: check reporting:participationCounts(pg),
            points: check reporting:pointsAwarded(pg),
            peopleWithPoints: (check recognition:recognitionTotals(pg, month + "-01", now)).employeesWithPoints,
            campaigns,
            delivery: check reporting:deliveryOf(pg, ids),
            shares: check sharing:shareHealth(pg, weekAgo),
            cards: check reporting:cardCounts(pg, time:utcAddSeconds(now, -30d * 86400d))
        };
        check commit;
    }
    return result ?: error("the dashboard snapshot was not taken");
}

# The month before `YYYY-MM`.
#
# + month - `YYYY-MM`
# + return - `YYYY-MM`
isolated function previousMonth(string month) returns string {
    int y = checkpanic int:fromString(month.substring(0, 4));
    int m = checkpanic int:fromString(month.substring(5, 7));
    return m == 1 ? string `${y - 1}-12` : string `${y}-${m - 1 < 10 ? "0" : ""}${m - 1}`;
}

# Reposts by category since a time (a per-request read, not in the snapshot: `days` varies).
#
# + since - Window start
# + return - Categories, or an error
isolated function categoryCounts(time:Utc since) returns reporting:CategoryCount[]|error {
    postgresql:Client pg = check db();
    return reporting:repostsByCategory(pg, since);
}

# One campaign's reposts by day since it opened, the first seven days.
#
# + campaignId - Campaign
# + return - Seven counts, or an error
isolated function campaignByDay(string campaignId) returns int[]|error {
    postgresql:Client pg = check db();
    return reporting:repostsByDay(pg, campaignId, 7);
}
