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

// The activity matrix in code. Mirrors architecture/solution/Phase 1/activity-matrix.md row for row:
// change both together. The interceptor enforces role × method × route (403); everything in `useCase`
// (state, ownership, kill switches) is checked by the use case behind the resource, never here.

# `amplify_po`
public const string ROLE_PO = "amplify_po";
# `amplify_marketing`
public const string ROLE_MARKETING = "amplify_marketing";
# `amplify_slt`
public const string ROLE_SLT = "amplify_slt";
# `amplify_admin`
public const string ROLE_ADMIN = "amplify_admin";

# Matrix columns. `EMP` is every signed-in employee; the others add to it.
public enum Audience {
    EMP,
    PO,
    MKT,
    SLT,
    ADM
}

# One row of the matrix.
public type Rule record {|
    # HTTP method, upper case
    string method;
    # Route template; `{name}` matches one path segment
    string path;
    # Columns allowed (anyone else gets 403)
    Audience[] allowed;
    # Capability this row grants, reported by `GET /me`
    string capability;
    # State and ownership conditions the use case checks (not the interceptor)
    string useCase = "";
|};

final Audience[] & readonly ALL = [EMP, PO, MKT, SLT, ADM];
final Audience[] & readonly CAMPAIGN_EDITORS = [PO, MKT];
# The dashboards: every amplify_* role, never a plain employee (ADR-036).
final Audience[] & readonly DASHBOARD_READERS = [PO, MKT, SLT, ADM];

# The matrix. First match wins; a route that isn't here is denied (default deny).
public final Rule[] & readonly ACTIVITY_MATRIX = [
    // Identity
    {method: "GET", path: "/me", allowed: ALL, capability: "me.read", useCase: "Own row only; upserts identity.employee"},
    // S1 Campaign
    {method: "GET", path: "/campaigns", allowed: ALL, capability: "campaigns.read", useCase: "EMP/SLT/ADM see OPEN only (default window 14d); PO/MKT any status"},
    {method: "GET", path: "/campaigns/{id}", allowed: ALL, capability: "campaigns.read", useCase: "EMP/SLT/ADM: OPEN campaigns only, else 404"},
    {method: "GET", path: "/tags", allowed: ALL, capability: "catalog.read"},
    {method: "GET", path: "/categories", allowed: ALL, capability: "catalog.read"},
    {method: "POST", path: "/campaigns", allowed: CAMPAIGN_EDITORS, capability: "campaigns.manage", useCase: "?shareNow=true also triggers amplify-jobs /runs; closes_at default (C7)"},
    {method: "PATCH", path: "/campaigns/{id}", allowed: CAMPAIGN_EDITORS, capability: "campaigns.manage", useCase: "Not on an archived campaign; optimistic lock"},
    {method: "DELETE", path: "/campaigns/{id}", allowed: CAMPAIGN_EDITORS, capability: "campaigns.manage", useCase: "Soft archive only"},
    // S2 Connection
    {method: "POST", path: "/connections/linkedin/start", allowed: ALL, capability: "linkedin.connect", useCase: "Own; issues state"},
    {method: "POST", path: "/connections/linkedin/complete", allowed: ALL, capability: "linkedin.connect", useCase: "Own; state matches, unused, unexpired, same employee"},
    {method: "DELETE", path: "/connections/linkedin", allowed: ALL, capability: "linkedin.connect", useCase: "Own"},
    // C1 Sharing
    {method: "POST", path: "/campaigns/{id}/shares", allowed: ALL, capability: "shares.create", useCase: "Own; campaign OPEN; connection ACTIVE/EXPIRING; one per campaign (retry reuses row, ADR-015); sharing.enabled"},
    {method: "GET", path: "/me/shares", allowed: ALL, capability: "shares.read_own"},
    // S3 External Sharing
    {method: "POST", path: "/external-shares", allowed: ALL, capability: "external_shares.submit", useCase: "Own; (evidence_url, action) unique (ADR-017); host allow-list"},
    {method: "GET", path: "/me/external-shares", allowed: ALL, capability: "external_shares.read_own"},
    {method: "GET", path: "/po/external-shares", allowed: [PO], capability: "external_shares.review"},
    {method: "POST", path: "/po/external-shares/{id}/approve", allowed: [PO], capability: "external_shares.review", useCase: "Only while PENDING; not own claim"},
    {method: "POST", path: "/po/external-shares/{id}/reject", allowed: [PO], capability: "external_shares.review", useCase: "Only while PENDING; reason required; not own claim"},
    {method: "POST", path: "/po/external-shares/{id}/amplified", allowed: [PO], capability: "external_shares.review", useCase: "Only on APPROVED (C4); once"},
    // C2 Scoring
    {method: "GET", path: "/po/point-rules", allowed: [PO], capability: "point_rules.manage"},
    {method: "POST", path: "/po/point-rules", allowed: [PO], capability: "point_rules.manage", useCase: "New version; past awards keep their value"},
    {method: "POST", path: "/po/points/adjustments", allowed: [PO], capability: "points.adjust", useCase: "Reason required; recognition in the same transaction (B12)"},
    {method: "POST", path: "/po/points/{reference}/reverse", allowed: [PO], capability: "points.adjust", useCase: "Reason required; not already reversed"},
    // S4 Recognition
    {method: "GET", path: "/leaderboard", allowed: ALL, capability: "leaderboard.read", useCase: "Top N, personal, My Team (ADR-014)"},
    {method: "GET", path: "/leaderboard/top", allowed: ALL, capability: "leaderboard.top.read", useCase: "Celebrate top three and My position, this week by default, company wide, weekly totals cached 2 hours (ADR-037)"},
    {method: "GET", path: "/leaderboard/people", allowed: ALL, capability: "leaderboard.people.read", useCase: "Company, BU or team board; open to every employee (ADR-035)"},
    {method: "GET", path: "/leaderboard/groups", allowed: ALL, capability: "leaderboard.groups.read", useCase: "Teams or BUs ranked; open to every employee (ADR-035)"},
    {method: "GET", path: "/headcount", allowed: ALL, capability: "headcount.read", useCase: "Employee count from the people directory, cached 7 days (ADR-035)"},
    {method: "GET", path: "/dashboards/operations", allowed: DASHBOARD_READERS, capability: "dashboards.operations.read", useCase: "Operations board (ADR-036)"},
    {method: "GET", path: "/dashboards/campaigns", allowed: DASHBOARD_READERS, capability: "dashboards.campaigns.read", useCase: "Campaign performance board"},
    {method: "GET", path: "/dashboards/export", allowed: DASHBOARD_READERS, capability: "dashboards.export.read", useCase: "Raw rows behind the boards for a date range, CSV"},
    {method: "GET", path: "/dashboards/people/{employeeId}", allowed: DASHBOARD_READERS, capability: "dashboards.people.read", useCase: "One person's Post Performance popup"},
    {method: "GET", path: "/dashboards/participation", allowed: DASHBOARD_READERS, capability: "dashboards.participation.read", useCase: "Participation funnel numbers"},
    {method: "GET", path: "/dashboards/glance", allowed: DASHBOARD_READERS, capability: "dashboards.glance.read", useCase: "At a glance numbers"},
    {method: "GET", path: "/dashboards/scorecard", allowed: DASHBOARD_READERS, capability: "dashboards.scorecard.read", useCase: "Scorecard against the scorecard.* targets"},
    {method: "GET", path: "/me/points", allowed: ALL, capability: "points.read_own"},
    {method: "GET", path: "/team", allowed: ALL, capability: "team.read", useCase: "Non-PO visibility per ADR-014/ADR-019"},
    {method: "GET", path: "/team/{employeeId}/history", allowed: ALL, capability: "team.history.read", useCase: "Non-PO: the caller, or a member of the caller's roster team (any employee when team.visibility = COMPANY), else 403 TEAM_SCOPE (leaderboards.md); PO any (team.history.read_any)"},
    {method: "GET", path: "/po/dashboard", allowed: [PO], capability: "po.dashboard"},
    {method: "GET", path: "/reports/participation", allowed: [SLT], capability: "reports.read", useCase: "Phase 2"},
    {method: "GET", path: "/reports/campaigns", allowed: [SLT], capability: "reports.read", useCase: "Phase 2"},
    // S5 / Admin
    {method: "GET", path: "/admin/announcements", allowed: [ADM], capability: "admin.announcements"},
    {method: "POST", path: "/admin/announcements/{id}/retry", allowed: [ADM], capability: "admin.announcements", useCase: "Only while FAILED; announcements.enabled"},
    {method: "GET", path: "/admin/settings", allowed: [ADM], capability: "admin.settings"},
    {method: "PUT", path: "/admin/settings", allowed: [ADM], capability: "admin.settings", useCase: "Optimistic lock; Coin settings hidden"},
    {method: "POST", path: "/admin/scheduler/sync", allowed: [ADM], capability: "admin.settings", useCase: "Pushes the schedule settings to the scheduler (ADR-026)"}
];

# Capabilities checked inside a use case rather than per route. Reported by `GET /me` so the UI can
# show the right controls.
public final Rule[] & readonly USE_CASE_CAPABILITIES = [
    {method: "GET", path: "/campaigns", allowed: CAMPAIGN_EDITORS, capability: "campaigns.read_any_status"},
    {method: "GET", path: "/team/{employeeId}/history", allowed: [PO], capability: "team.history.read_any"}
];

# Routes that skip authentication: probes only, never published through the proxy.
public final string[] & readonly PUBLIC_PATHS = ["/health", "/ready"];

# Finds the matrix row for a call.
#
# + method - HTTP method
# + segments - Decoded path segments
# + return - The row, or `()` when the route isn't in the matrix
public isolated function findRule(string method, string[] segments) returns Rule? {
    string verb = method.toUpperAscii();
    foreach Rule rule in ACTIVITY_MATRIX {
        if rule.method == verb && matches(rule.path, segments) {
            return rule;
        }
    }
    return ();
}

# Matrix columns for a set of IdP roles. Everyone is `EMP`; unknown roles add nothing.
#
# + roles - `amplify_*` roles from the token
# + return - Columns
public isolated function audiences(string[] roles) returns Audience[] {
    Audience[] result = [EMP];
    foreach string role in roles {
        Audience? column = role == ROLE_PO ? PO : role == ROLE_MARKETING ? MKT : role == ROLE_SLT ? SLT
            : role == ROLE_ADMIN ? ADM : ();
        if column is Audience && result.indexOf(column) is () {
            result.push(column);
        }
    }
    return result;
}

# Whether the caller's roles allow a row.
#
# + rule - Matrix row
# + roles - `amplify_*` roles
# + return - True when one of the caller's columns is allowed
public isolated function isAllowed(Rule rule, string[] roles) returns boolean {
    foreach Audience column in audiences(roles) {
        if rule.allowed.indexOf(column) !is () {
            return true;
        }
    }
    return false;
}

# Capabilities for `GET /me`, derived from the matrix (route rows plus use-case rows).
#
# + roles - `amplify_*` roles
# + return - Distinct capability ids, sorted
public isolated function capabilities(string[] roles) returns string[] {
    string[] result = [];
    foreach Rule rule in [...ACTIVITY_MATRIX, ...USE_CASE_CAPABILITIES] {
        if isAllowed(rule, roles) && result.indexOf(rule.capability) is () {
            result.push(rule.capability);
        }
    }
    return result.sort();
}

# Whether a path is a probe.
#
# + segments - Decoded path segments
# + return - True for `/health` and `/ready`
public isolated function isPublic(string[] segments) returns boolean =>
    segments.length() == 1 && PUBLIC_PATHS.indexOf("/" + segments[0]) !is ();

isolated function matches(string template, string[] segments) returns boolean {
    string[] parts = re `/`.split(template.substring(1));
    if parts.length() != segments.length() {
        return false;
    }
    foreach int i in 0 ..< parts.length() {
        string part = parts[i];
        boolean isParam = part.startsWith("{") && part.endsWith("}");
        if isParam ? segments[i].length() == 0 : part != segments[i] {
            return false;
        }
    }
    return true;
}
