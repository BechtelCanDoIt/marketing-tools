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


// The dashboard queries. Pure SQL over views and tables the API role can already read; each one is a small
// indexed aggregate at pilot volume (~830 employees, tens of campaigns).

import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Campaigns live now.
public type LiveCounts record {|
    # Open now
    int live;
    # Open now and flagged priority
    int livePriority;
    # Open now and closing within seven days
    int closingWithin7Days;
|};

# One campaign and what was recorded against it.
public type CampaignRow record {|
    # Campaign id
    string campaignId;
    # Title
    string title;
    # Category code
    string categoryCode;
    # Category label (the code when the category is gone)
    string categoryLabel;
    # Priority flag
    boolean isPriority;
    # SCHEDULED, OPEN, CLOSED or ARCHIVED
    string status;
    # Opens
    time:Utc opensAt;
    # Closes
    time:Utc closesAt;
    # Active engagements recorded against the campaign
    int reposts;
|};

# Connections by derived state.
public type ConnectionBreakdown record {|
    # Working
    int active;
    # Inside the reminder window
    int expiring;
    # Token past its expiry
    int expired;
    # Needs reconnect for another reason (revoked, token missing)
    int revoked;
|};

# A campaign's announcement as the outbox sees it.
public type Delivery record {|
    # `QUEUED`, `SENT` or `FAILED` (a campaign without an announcement row is left out)
    string status;
    # Outbox attempts so far while queued
    int? attempts;
    # When the card went out
    time:Utc? sentAt;
|};

# Reposts in one calendar week.
public type WeekCount record {|
    # Monday, `YYYY-MM-DD` (UTC)
    string weekStart;
    # Active engagements
    int reposts;
|};

# Reposts per category.
public type CategoryCount record {|
    # Code
    string code;
    # Label
    string label;
    # Active engagements
    int reposts;
|};

# People at each step of the participation funnel.
public type ParticipationCounts record {|
    # Not removed, any state
    int connected;
    # Token past its expiry
    int expired;
    # At least one active engagement
    int reposted;
    # An engagement in the last 30 days
    int active30Days;
|};

# Announcements of campaigns that opened in a window.
public type CardCounts record {|
    # Campaigns that opened in the window
    int total;
    # Card sent
    int sent;
    # Not sent yet, still retrying or waiting
    int queued;
    # Gave up after the retries (admin retry needed)
    int failed;
    # Queued with at least one failed attempt
    int retrying;
|};

# Open campaigns, counted.
#
# + db - Client
# + return - Counts, or an error
public isolated function liveCounts(postgresql:Client db) returns LiveCounts|error {
    return db->queryRow(`
        SELECT count(*)::int AS live,
               count(*) FILTER (WHERE is_priority)::int AS "livePriority",
               count(*) FILTER (WHERE closes_at <= now() + interval '7 days')::int AS "closingWithin7Days"
        FROM campaign.campaign_v WHERE status = 'OPEN'`);
}

# Active engagements in a time range.
#
# + db - Client
# + from - Start, inclusive
# + to - End, exclusive
# + return - Count, or an error
public isolated function repostsBetween(postgresql:Client db, time:Utc 'from, time:Utc to) returns int|error {
    string a = time:utcToString('from);
    string b = time:utcToString(to);
    return db->queryRow(`
        SELECT count(*)::int FROM sharing.engagement_v
        WHERE status = 'ACTIVE' AND occurred_at >= CAST(${a} AS timestamptz) AND occurred_at < CAST(${b} AS timestamptz)`);
}

# Campaigns that are open or opened in the last `days`, with their repost counts (not archived).
#
# + db - Client
# + days - Look-back
# + limit - Most rows
# + now - Current time
# + return - Campaigns, priority first then newest, or an error
public isolated function campaignRows(postgresql:Client db, int days, int 'limit, time:Utc now) returns CampaignRow[]|error {
    string since = time:utcToString(time:utcAddSeconds(now, -86400d * <decimal>days));
    stream<record {|
        string id;
        string title;
        string category_code;
        string category_label;
        boolean is_priority;
        string status;
        time:Utc opens_at;
        time:Utc closes_at;
        int reposts;
    |}, error?> rows = db->query(`
        SELECT c.id::text AS id, c.title, c.category_code, COALESCE(cat.label, c.category_code) AS category_label,
               c.is_priority, c.status, c.opens_at, c.closes_at, COALESCE(e.n, 0)::int AS reposts
        FROM campaign.campaign_v c
        LEFT JOIN campaign.category cat ON cat.code = c.category_code
        LEFT JOIN (SELECT campaign_id, count(*) AS n FROM sharing.engagement_v WHERE status = 'ACTIVE'
                   GROUP BY campaign_id) e ON e.campaign_id = c.id
        WHERE c.archived_at IS NULL AND c.status IN ('OPEN', 'CLOSED')
          AND (c.status = 'OPEN' OR c.opens_at >= CAST(${since} AS timestamptz))
        ORDER BY c.is_priority DESC, c.opens_at DESC, c.id
        LIMIT ${'limit}`);
    return from var r in rows
        select {
            campaignId: r.id,
            title: r.title,
            categoryCode: r.category_code,
            categoryLabel: r.category_label,
            isPriority: r.is_priority,
            status: r.status,
            opensAt: r.opens_at,
            closesAt: r.closes_at,
            reposts: r.reposts
        };
}

# Connections by state. `expired` is the token being past its expiry; `revoked` is every other reason the
# derived state says reconnect.
#
# + db - Client
# + return - Counts, or an error
public isolated function connectionBreakdown(postgresql:Client db) returns ConnectionBreakdown|error {
    return db->queryRow(`
        SELECT count(*) FILTER (WHERE status = 'ACTIVE')::int AS active,
               count(*) FILTER (WHERE status = 'EXPIRING')::int AS expiring,
               count(*) FILTER (WHERE status = 'NEEDS_RECONNECT' AND access_expires_at <= now())::int AS expired,
               count(*) FILTER (WHERE status = 'NEEDS_RECONNECT' AND access_expires_at > now())::int AS revoked
        FROM connection.member_connection_v WHERE status <> 'REMOVED'`);
}

# Announcement delivery by campaign: the card's state and how many times the outbox has tried.
#
# + db - Client
# + campaignIds - Campaigns
# + return - Delivery by campaign id (campaigns without an announcement row are left out), or an error
public isolated function deliveryOf(postgresql:Client db, string[] campaignIds) returns map<Delivery>|error {
    string ids = store:arrayLiteral(campaignIds);
    stream<record {|string campaign_id; string status; int? attempts; time:Utc? sent_at;|}, error?> rows = db->query(`
        SELECT a.campaign_id::text AS campaign_id, a.status, o.attempts, a.sent_at
        FROM announcement.announcement_v a
        LEFT JOIN messaging.outbox o ON o.id = a.outbox_id
        WHERE a.campaign_id = ANY (CAST(${ids} AS uuid[]))`);
    map<Delivery> result = {};
    check from var r in rows
        do {
            result[r.campaign_id] = {status: r.status, attempts: r.status == "QUEUED" ? r.attempts : (), sentAt: r.sent_at};
        };
    return result;
}

# Cards for campaigns that opened in a window: sent, still queued (and retrying), or failed for good.
#
# + db - Client
# + since - Window start
# + return - Counts, or an error
public isolated function cardCounts(postgresql:Client db, time:Utc since) returns CardCounts|error {
    string s = time:utcToString(since);
    return db->queryRow(`
        SELECT count(*)::int AS total,
               count(*) FILTER (WHERE a.status = 'SENT')::int AS sent,
               count(*) FILTER (WHERE a.status = 'FAILED')::int AS failed,
               count(*) FILTER (WHERE a.status IS DISTINCT FROM 'SENT' AND a.status IS DISTINCT FROM 'FAILED')::int AS queued,
               count(*) FILTER (WHERE a.status = 'QUEUED' AND COALESCE(o.attempts, 0) > 0)::int AS retrying
        FROM campaign.campaign_v c
        LEFT JOIN announcement.announcement_v a ON a.campaign_id = c.id
        LEFT JOIN messaging.outbox o ON o.id = a.outbox_id
        WHERE c.archived_at IS NULL AND c.opens_at <= now() AND c.opens_at >= CAST(${s} AS timestamptz)`);
}

# A campaign's reposts by day since it opened (day 1 = the first 24 hours), days 1 to `days`.
#
# + db - Client
# + campaignId - Campaign
# + days - Number of days
# + return - One count per day, zero-filled, or an error
public isolated function repostsByDay(postgresql:Client db, string campaignId, int days) returns int[]|error {
    stream<record {|int day; int n;|}, error?> rows = db->query(`
        SELECT (floor(extract(epoch FROM (e.occurred_at - c.opens_at)) / 86400)::int + 1) AS day, count(*)::int AS n
        FROM sharing.engagement_v e
        JOIN campaign.campaign c ON c.id = e.campaign_id
        WHERE e.status = 'ACTIVE' AND e.campaign_id = CAST(${campaignId} AS uuid)
        GROUP BY 1`);
    int[] counts = [];
    foreach int _ in 0 ..< days {
        counts.push(0);
    }
    check from var r in rows
        do {
            if r.day >= 1 && r.day <= days {
                counts[r.day - 1] = r.n;
            }
        };
    return counts;
}

# Reposts by category since a time.
#
# + db - Client
# + since - Start
# + return - Categories with reposts, most first, or an error
public isolated function repostsByCategory(postgresql:Client db, time:Utc since) returns CategoryCount[]|error {
    string s = time:utcToString(since);
    stream<record {|string code; string label; int n;|}, error?> rows = db->query(`
        SELECT c.category_code AS code, COALESCE(cat.label, c.category_code) AS label, count(*)::int AS n
        FROM sharing.engagement_v e
        JOIN campaign.campaign c ON c.id = e.campaign_id
        LEFT JOIN campaign.category cat ON cat.code = c.category_code
        WHERE e.status = 'ACTIVE' AND e.occurred_at >= CAST(${s} AS timestamptz)
        GROUP BY c.category_code, cat.label
        ORDER BY n DESC, label`);
    return from var r in rows
        select {code: r.code, label: r.label, reposts: r.n};
}

# People at each step of the participation funnel.
#
# + db - Client
# + return - Counts, or an error
public isolated function participationCounts(postgresql:Client db) returns ParticipationCounts|error {
    return db->queryRow(`
        SELECT (SELECT count(*) FROM connection.member_connection_v WHERE status <> 'REMOVED')::int AS connected,
               (SELECT count(*) FROM connection.member_connection_v
                WHERE status = 'NEEDS_RECONNECT' AND access_expires_at <= now())::int AS expired,
               (SELECT count(DISTINCT employee_id) FROM sharing.engagement_v WHERE status = 'ACTIVE')::int AS reposted,
               (SELECT count(DISTINCT employee_id) FROM sharing.engagement_v
                WHERE status = 'ACTIVE' AND occurred_at >= now() - interval '30 days')::int AS "active30Days"`);
}

# Reposts per calendar week (Monday, UTC) for the last `weeks` weeks, zero-filled, oldest first.
#
# + db - Client
# + weeks - Number of weeks
# + return - One row per week, or an error
public isolated function weeklyReposts(postgresql:Client db, int weeks) returns WeekCount[]|error {
    stream<record {|string week_start; int n;|}, error?> rows = db->query(`
        SELECT to_char(w.week_start, 'YYYY-MM-DD') AS week_start, count(e.id)::int AS n
        FROM generate_series(date_trunc('week', now() AT TIME ZONE 'UTC') - make_interval(weeks => CAST(${weeks - 1} AS int)),
                             date_trunc('week', now() AT TIME ZONE 'UTC'), interval '1 week') AS w(week_start)
        LEFT JOIN sharing.engagement_v e
               ON e.status = 'ACTIVE'
              AND date_trunc('week', e.occurred_at AT TIME ZONE 'UTC') = w.week_start
        GROUP BY w.week_start ORDER BY w.week_start`);
    return from var r in rows
        select {weekStart: r.week_start, reposts: r.n};
}

# People with at least one active engagement.
#
# + db - Client
# + return - Count, or an error
public isolated function repostingPeople(postgresql:Client db) returns int|error {
    return db->queryRow(`SELECT count(DISTINCT employee_id)::int FROM sharing.engagement_v WHERE status = 'ACTIVE'`);
}

# Points awarded in a month (employee_points_monthly).
#
# + db - Client
# + month - `YYYY-MM-01`
# + return - Points this month, or an error
public isolated function pointsInMonth(postgresql:Client db, string month) returns int|error {
    return db->queryRow(`
        SELECT COALESCE(sum(points), 0)::int FROM recognition.employee_points_monthly
        WHERE month = CAST(${month} AS date)`);
}
