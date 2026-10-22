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

// Fakes for the read seams (database.bal reads, the people directory, LinkedIn OAuth, the token cipher, OAuth
// state, tokens and announcements). The reads honour the DB breaker the way the real ones do: while it isn't
// closed they go through `db()`, so an open breaker still answers 503 (db_breaker_test.bal).

import amplify_common.crypto;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.recognition;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/http;
import ballerina/test;
import ballerina/time;

const string TEST_REDIRECT_URI = "https://one.wso2.test/amplify/linkedin/callback";

# Reads only touch `db()` while the breaker isn't closed, like a real read whose pool is refused.
#
# + return - The breaker's error, or `()`
isolated function dbGate() returns error? {
    if dbBreakerState() != "CLOSED" {
        _ = check db();
    }
}

// ---- People directory (team rosters) ------------------------------------------------------------

# Pretends `peopleDirectoryUrl` is empty (the state before D13 closes).
isolated boolean rosterOff = false;

function setRosterOff(boolean off) {
    lock {
        rosterOff = off;
    }
}

@test:Mock {functionName: "rosterConfigured"}
isolated function mockRosterConfigured() returns boolean {
    lock {
        return !rosterOff;
    }
}

# How the fake directory answers: `ok`, `down` (418, not a breaker status, so the breaker stays closed for
# the other tests) or `garbled` (a body that isn't a directory).
isolated string directoryMode = "ok";
isolated int directoryFetches = 0;

# Sets the fake's answer and drops amplify-api's cached index, so the next read fetches again.
#
# + mode - `ok`, `down` or `garbled`
function setDirectory(string mode) {
    lock {
        directoryMode = mode;
    }
    lock {
        directoryCache = ();
    }
    lock {
        headcountCache = ();
    }
}

function takeDirectoryFetches() returns int {
    lock {
        int n = directoryFetches;
        directoryFetches = 0;
        return n;
    }
}

# Ages the cached index past `rosterCacheSeconds`, as if three days went by.
function expireDirectoryCache() {
    lock {
        [DirectoryIndex & readonly, decimal]? hit = directoryCache;
        if hit is [DirectoryIndex & readonly, decimal] {
            directoryCache = [hit[0], hit[1] - rosterCacheSeconds - 1d];
        }
    }
}

# Ages the cached employee count past `headcountCacheSeconds`, as if a week went by.
function expireHeadcountCache() {
    lock {
        [HeadcountSnapshot & readonly, decimal]? hit = headcountCache;
        if hit is [HeadcountSnapshot & readonly, decimal] {
            headcountCache = [hit[0], hit[1] - headcountCacheSeconds - 1d];
        }
    }
}

final readonly & string[] RIVERS = ["rv-a@wso2.com", "rv-b@wso2.com", "rv+plus@wso2.com"];

service /people/employees/basic\-info on jwksListener {
    isolated resource function get .() returns json|http:Response {
        string mode;
        lock {
            directoryFetches += 1;
        }
        lock {
            mode = directoryMode;
        }
        if mode == "down" {
            http:Response res = new;
            res.statusCode = 418;
            return res;
        }
        if mode == "garbled" {
            return {teamName: "Rivers", members: [{name: "Bob Jones bob@wso2.com"}]};
        }
        json[] rows = from string m in RIVERS
            select {workEmail: m.toUpperAscii(), firstName: "R", team: "Rivers", subTeam: (), businessUnit: "Water"};
        rows.push({workEmail: "rv-noteam@wso2.com", firstName: "N", team: (), subTeam: (), businessUnit: "Land"});
        return rows;
    }
}

// ---- Standings ---------------------------------------------------------------------------------

function standing(string id, int points, int rank) returns recognition:Standing => {
    periodKey: "ALL",
    employeeId: id,
    displayName: "Person " + id,
    email: id + "@wso2.com",
    totalPoints: points,
    rank,
    previousRank: (),
    pointsToNextRank: 0,
    pointsToTopN: 0,
    lastActivityAt: [1760000000, 0]
};

final readonly & recognition:Standing[] STANDINGS = [
    standing("lb-1", 500, 1), standing("lb-2", 400, 2), standing("rv-a", 300, 3), standing("lb-3", 200, 4),
    standing("rv-b", 150, 5), standing("rv-c", 100, 6)
].cloneReadOnly();

isolated int fakeStandingVersion = 7;

function bumpStandingVersion() {
    lock {
        fakeStandingVersion += 1;
    }
}

@test:Mock {functionName: "standingVersion"}
isolated function mockStandingVersion(string period) returns int|error {
    check dbGate();
    lock {
        return fakeStandingVersion;
    }
}

@test:Mock {functionName: "topStandings"}
isolated function mockTopStandings(string period, int topN) returns recognition:Standing[]|error {
    check dbGate();
    return STANDINGS.slice(0, topN < STANDINGS.length() ? topN : STANDINGS.length()).clone();
}

@test:Mock {functionName: "standingOf"}
isolated function mockStandingOf(types:EmployeeId employeeId, string period) returns recognition:Standing|error? {
    check dbGate();
    foreach recognition:Standing s in STANDINGS {
        if s.employeeId == employeeId {
            return s.clone();
        }
    }
    return ();
}

@test:Mock {functionName: "standingEmailOf"}
isolated function mockStandingEmailOf(types:EmployeeId employeeId) returns string|error? {
    check dbGate();
    foreach recognition:Standing s in STANDINGS {
        if s.employeeId == employeeId {
            return s.email;
        }
    }
    return ();
}

@test:Mock {functionName: "teamPageOf"}
isolated function mockTeamPageOf(string period, string[]? emails, string? q, recognition:TeamSort sort, int page, int size)
        returns recognition:TeamPage|error {
    check dbGate();
    recognition:Standing[] rows = from recognition:Standing s in STANDINGS
        where (emails is () || emails.indexOf(s.email) !is ()) && (q is () || s.displayName.includes(q))
        select s;
    recognition:TeamEntry[] items = [];
    foreach int i in 0 ..< rows.length() {
        if i >= page * size && i < (page + 1) * size {
            items.push({standing: rows[i].clone(), teamRank: i + 1});
        }
    }
    return {items, total: rows.length()};
}

@test:Mock {functionName: "pointsByEmailOf"}
isolated function mockPointsByEmailOf(string period) returns recognition:EmailPoints[]|error {
    check dbGate();
    return from recognition:Standing s in STANDINGS
        select {email: s.email, totalPoints: s.totalPoints};
}

@test:Mock {functionName: "monthlyPoints"}
isolated function mockMonthlyPoints(types:EmployeeId employeeId) returns recognition:MonthPoints[]|error {
    check dbGate();
    return [{month: "2026-10", points: 30, actions: 2}, {month: "2026-09", points: 10, actions: 1}];
}

@test:Mock {functionName: "ledgerHistory"}
isolated function mockLedgerHistory(types:EmployeeId employeeId, int page, int size) returns scoring:LedgerPage|error {
    check dbGate();
    types:LedgerEntry entry = {
        reference: "ADJ:" + employeeId + ":1",
        employeeId,
        campaignId: (),
        sourceType: types:ADJUSTMENT,
        action: (),
        points: 10,
        reason: "Welcome bonus",
        reversesReference: (),
        actorId: "po-0001",
        createdAt: [1760000000, 0],
        status: (),
        sourceId: (),
        ruleId: (),
        correlationId: (),
        statusChangedAt: (),
        paidAt: (),
        coinReference: ()
    };
    return {items: [entry], total: 1};
}

@test:Mock {functionName: "sharesOf"}
isolated function mockSharesOf(types:EmployeeId employeeId) returns sharing:ShareView[]|error {
    check dbGate();
    return [];
}

@test:Mock {functionName: "claimsOf"}
isolated function mockClaimsOf(types:EmployeeId employeeId) returns external_sharing:ExternalShare[]|error {
    check dbGate();
    return [];
}

@test:Mock {functionName: "claimsForReview"}
isolated function mockClaimsForReview(external_sharing:ExternalShareStatus? status, int page, int size)
        returns external_sharing:ExternalSharePage|error {
    check dbGate();
    return {items: [], total: 0};
}

isolated int dashboardBuilds = 0;

function dashboardBuildCount() returns int {
    lock {
        return dashboardBuilds;
    }
}

@test:Mock {functionName: "dashboardData"}
isolated function mockDashboardData(string month, int slaHours, time:Utc now) returns json|error {
    check dbGate();
    lock {
        dashboardBuilds += 1;
    }
    return {asOf: time:utcToString(now), month, reviewQueue: {pending: 0, oldestPendingAt: (), overSla: 0, slaHours}};
}

// ---- LinkedIn OAuth, cipher, OAuth state, tokens ----------------------------------------------------

# How the fake LinkedIn answers the code exchange.
type LinkedInMode "OK"|"REJECTED"|"DOWN"|"OFF";

isolated LinkedInMode linkedInMode = "OK";

function setLinkedInMode(LinkedInMode mode) {
    lock {
        linkedInMode = mode;
    }
}

isolated function currentLinkedInMode() returns LinkedInMode {
    lock {
        return linkedInMode;
    }
}

isolated class FakeLinkedIn {
    *linkedin:ProviderAdapter;

    public isolated function authorizationUrl(string state) returns string|linkedin:ProviderError =>
        "https://www.linkedin.com/oauth/v2/authorization?response_type=code&state=" + state;

    public isolated function exchangeCode(string code) returns linkedin:TokenGrant|linkedin:ProviderError {
        LinkedInMode mode = currentLinkedInMode();
        if mode == "REJECTED" {
            return error linkedin:ProviderError("bad code", code = linkedin:REJECTED, httpStatus = 400,
                serviceErrorCode = (), retryable = false);
        }
        if mode == "DOWN" {
            return error linkedin:ProviderError("down", code = linkedin:UNAVAILABLE, httpStatus = 503,
                serviceErrorCode = (), retryable = true);
        }
        return {accessToken: "li-token-" + code, expiresInSeconds: 5184000, scopes: ["openid", "profile", "w_member_social"],
            idToken: nextIdToken()};
    }

    public isolated function userInfo(string accessToken) returns linkedin:MemberProfile|linkedin:ProviderError =>
        {sub: "li-" + accessToken, memberUrn: "urn:li:person:" + accessToken.substring(accessToken.length() - 6),
            name: (), email: ()};

    public isolated function publishShare(string accessToken, linkedin:ShareCommand command)
            returns types:PostUrn|linkedin:ProviderError =>
        error linkedin:ProviderError("not in api tests", code = linkedin:UNAVAILABLE, httpStatus = 503,
            serviceErrorCode = (), retryable = true);
}

final FakeLinkedIn fakeLinkedIn = new;

// ID token the fake's next code exchange returns (`()` = none, as LinkedIn without `openid`).
isolated string? idTokenOnExchange = ();

function setIdTokenOnExchange(string? token) {
    lock {
        idTokenOnExchange = token;
    }
}

isolated function nextIdToken() returns string? {
    lock {
        return idTokenOnExchange;
    }
}

@test:Mock {functionName: "linkedInProvider"}
isolated function mockLinkedInProvider() returns linkedin:ProviderAdapter? =>
    currentLinkedInMode() == "OFF" ? () : fakeLinkedIn;

final crypto:TokenCipher testCipher = check new ([check crypto:keyFromBase64("k1",
    "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")], "k1");

@test:Mock {functionName: "cipher"}
isolated function mockCipher() returns crypto:TokenCipher? => testCipher;

@test:Mock {functionName: "redirectUri"}
isolated function mockRedirectUri() returns string => TEST_REDIRECT_URI;

isolated class FakeOAuthStates {
    *connection:OAuthStateRepository;
    private map<connection:OAuthState> rows = {};

    public isolated function issue(connection:OAuthState state) returns error? {
        lock {
            self.rows[state.state] = state.clone();
        }
    }

    public isolated function consume(string state, types:EmployeeId employeeId, time:Utc now)
            returns connection:OAuthState|error? {
        lock {
            connection:OAuthState? row = self.rows[state];
            if row is () || row.employeeId != employeeId || time:utcDiffSeconds(row.expiresAt, now) <= 0d {
                return ();
            }
            _ = self.rows.remove(state);
            return row.clone();
        }
    }
}

isolated class FakeTokens {
    *connection:TokenRepository;
    private connection:StoredToken[] rows = [];

    public isolated function insert(connection:StoredToken token) returns error? {
        lock {
            self.rows.push(token.clone());
        }
    }

    public isolated function find(connection:TokenRef ref) returns connection:StoredToken|error? => ();

    isolated function count() returns int {
        lock {
            return self.rows.length();
        }
    }
}

final FakeOAuthStates fakeOAuthStates = new;
final FakeTokens fakeTokens = new;

@test:Mock {functionName: "oauthStateRepository"}
isolated function mockOAuthStateRepository() returns connection:OAuthStateRepository|error => fakeOAuthStates;

@test:Mock {functionName: "tokenRepository"}
isolated function mockTokenRepository() returns connection:TokenRepository|error => fakeTokens;

// ---- Announcements --------------------------------------------------------------------------------

isolated class FakeAnnouncements {
    *announcements:AnnouncementRepository;
    private map<announcements:Announcement> rows = {};

    isolated function put(announcements:Announcement a) {
        lock {
            self.rows[a.campaignId] = a.clone();
        }
    }

    public isolated function findByCampaign(string campaignId) returns announcements:Announcement|error? {
        lock {
            return self.rows[campaignId].clone();
        }
    }

    public isolated function list(announcements:AnnouncementStatus? status, int 'limit)
            returns announcements:Announcement[]|error {
        announcements:Announcement[] all;
        lock {
            all = self.rows.toArray().clone();
        }
        return from announcements:Announcement a in all
            where status is () || announcements:announcementStatus(a) == status
            select a;
    }

    public isolated function requeue(string campaignId) returns error? {
        lock {
            announcements:Announcement? a = self.rows[campaignId];
            if a is announcements:Announcement {
                announcements:Announcement queued = a.clone();
                queued.failedAt = ();
                queued.lastError = ();
                self.rows[campaignId] = queued;
            }
        }
    }
}

final FakeAnnouncements fakeAnnouncements = new;

@test:Mock {functionName: "announcementRepository"}
isolated function mockAnnouncementRepository(store:Actor actor) returns announcements:AnnouncementRepository|error =>
    fakeAnnouncements;
