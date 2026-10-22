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


// Everything the five dashboards need, read at one instant (ADR-036). One REPEATABLE READ, READ ONLY
// transaction, so the ~15 statements all see the same committed state: a repost committed by amplify-jobs
// mid-read shows in every number or in none.

import amplify_domain.recognition;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Everything the five boards need, as of one moment.
public type Snapshot record {|
    # When it was taken
    time:Utc asOf;
    # Campaigns open now
    LiveCounts live;
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
    WeekCount[] weekly;
    # Connections by state
    ConnectionBreakdown connections;
    # The funnel
    ParticipationCounts participation;
    # Points awarded this week, month and year (UTC calendar)
    PointsAwarded points;
    # People with points
    int peopleWithPoints;
    # Open campaigns and campaigns opened in the last 90 days, priority first then newest (at most 200)
    CampaignRow[] campaigns;
    # Announcement delivery by campaign id
    map<Delivery> delivery;
    # Shares in the last 7 days
    sharing:ShareHealth shares;
    # Cards for campaigns opened in the last 30 days
    CardCounts cards;
|};

# Reads the snapshot in one gated, repeatable-read, read-only transaction (R-13).
#
# + db - Client
# + now - Current time
# + return - The snapshot, or an error
public isolated function loadSnapshot(postgresql:Client db, time:Utc now) returns Snapshot|error {
    final readonly & time:Utc at = now.cloneReadOnly();
    return (check store:inTransactionValue(() => snapshotTx(db, at))).ensureType();
}

isolated function snapshotTx(postgresql:Client db, time:Utc now) returns Snapshot|error {
    Snapshot? result = ();
    string month = time:utcToString(now).substring(0, 7);
    time:Utc monthStart = check time:utcFromString(month + "-01T00:00:00Z");
    time:Utc prevMonthStart = check time:utcFromString(previousMonth(month) + "-01T00:00:00Z");
    time:Utc soon = time:utcAddSeconds(now, 60);
    time:Utc weekAgo = time:utcAddSeconds(now, -7d * 86400d);
    time:Utc twoWeeksAgo = time:utcAddSeconds(now, -14d * 86400d);
    transaction {
        // First statement of the transaction: every query below sees one committed state.
        _ = check db->execute(`SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY`);
        CampaignRow[] campaigns = check campaignRows(db, 90, 200, now);
        string[] ids = from CampaignRow p in campaigns
            select p.campaignId;
        result = {
            asOf: now,
            live: check liveCounts(db),
            reposts7d: check repostsBetween(db, weekAgo, soon),
            reposts7dWithCommentary: check commentaryRepostsBetween(db, weekAgo, soon),
            repostsPrev7d: check repostsBetween(db, twoWeeksAgo, weekAgo),
            repostsThisMonth: check repostsBetween(db, monthStart, soon),
            repostsPrevMonth: check repostsBetween(db, prevMonthStart, monthStart),
            weekly: check weeklyReposts(db, 8),
            connections: check connectionBreakdown(db),
            participation: check participationCounts(db),
            points: check pointsAwarded(db),
            peopleWithPoints: (check recognition:recognitionTotals(db, month + "-01", now)).employeesWithPoints,
            campaigns,
            delivery: check deliveryOf(db, ids),
            shares: check sharing:shareHealth(db, weekAgo),
            cards: check cardCounts(db, time:utcAddSeconds(now, -30d * 86400d))
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
