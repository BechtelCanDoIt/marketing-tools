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
import amplify_api.auth;
import amplify_common.types;
import amplify_domain.store;

import ballerina/crypto;
import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

// No client cache: `/leaderboard` is `private, max-age=30`, and a cached 200 would answer the anonymous and
// breaker-open calls of later tests without reaching the server.
final http:Client api = check new (string `http://localhost:${port}`, {cache: {enabled: false}});

function call(string method, string path, string? token) returns http:Response|error {
    map<string> headers = {};
    if token is string {
        headers = {"x-jwt-assertion": token, "X-Correlation-ID": "test-corr-1"};
    }
    return api->execute(method, path, method == "GET" ? () : {}, headers);
}

function codeOf(http:Response res) returns string|error {
    json body = check res.getJsonPayload();
    return (check body.code).toString();
}

// ---- Authentication: 401 ------------------------------------------------------------------------

@test:Config
function testMissingTokenIs401() returns error? {
    _ = takeDenials();
    http:Response res = check call("GET", "/me", ());
    test:assertEquals(res.statusCode, 401);
    test:assertEquals(res.getContentType(), "application/problem+json");
    test:assertEquals(check codeOf(res), auth:TOKEN_MISSING);
    store:AuditEntry[] audit = takeDenials();
    test:assertEquals(audit.length(), 1);
    test:assertEquals(audit[0].actorId, "anonymous");
    test:assertEquals(audit[0].outcome, "DENIED");
    test:assertEquals(audit[0].reason, auth:TOKEN_MISSING);
}

@test:Config
function testInvalidTokensAre401() returns error? {
    _ = takeDenials();
    int now = time:utcNow()[0];
    crypto:PrivateKey rogue = check rogueKey.ensureType();
    [string, string][] cases = [
        [check mint({exp: now - 3600, iat: now - 7200}), auth:TOKEN_EXPIRED],
        [check mint({exp: ()}), auth:TOKEN_EXPIRED],
        [check mint({aud: "someone-else"}), auth:TOKEN_AUDIENCE_INVALID],
        [check mint({iss: "https://evil.example"}), auth:TOKEN_ISSUER_INVALID],
        [check mint(key = rogue), auth:TOKEN_SIGNATURE_INVALID],
        [check mint(header = {alg: "HS256"}), auth:TOKEN_ALG_NOT_ALLOWED],
        [check mint({sub: ()}), auth:TOKEN_CLAIMS_INVALID],
        [check mint({email: ()}), auth:TOKEN_CLAIMS_INVALID],
        [check mint({nbf: now + 3600}), auth:TOKEN_NOT_YET_VALID],
        ["not-a-jwt", auth:TOKEN_MALFORMED]
    ];
    foreach [string, string] [token, expected] in cases {
        http:Response res = check call("GET", "/me", token);
        test:assertEquals(res.statusCode, 401, expected);
        test:assertEquals(check codeOf(res), expected);
    }
    store:AuditEntry[] audit = takeDenials();
    test:assertEquals(audit.length(), cases.length());
    foreach store:AuditEntry entry in audit {
        test:assertEquals(entry.correlationId, "test-corr-1");
        test:assertFalse(entry.toJsonString().includes("eyJ"), "token leaked into the audit row");
    }
}

@test:Config
function testUnsignedTokenIs401() returns error? {
    string token = check mint();
    string unsigned = token.substring(0, <int>token.lastIndexOf(".")) + ".";
    http:Response res = check call("GET", "/me", unsigned);
    test:assertEquals(res.statusCode, 401);
}

@test:Config
function testProbesNeedNoToken() returns error? {
    http:Response res = check call("GET", "/health", ());
    test:assertEquals(res.statusCode, 200);
}

// ---- Authorization: activity matrix -------------------------------------------------------------

@test:Config
function testActivityMatrixSample() returns error? {
    // [method, path, groups, expected]. 0 = passed the interceptor (any status but 401/403).
    [string, string, string[], int][] cases = [
        ["GET", "/me", [], 200],
        ["GET", "/me", [auth:ROLE_SLT], 200],
        ["GET", "/leaderboard", [], 0],
        ["GET", "/po/dashboard", [], 403],
        ["GET", "/po/dashboard", [auth:ROLE_MARKETING], 403],
        ["GET", "/po/dashboard", [auth:ROLE_PO], 0],
        ["POST", "/campaigns", [], 403],
        ["POST", "/campaigns", [auth:ROLE_SLT], 403],
        ["POST", "/campaigns", [auth:ROLE_MARKETING], 0],
        ["POST", "/campaigns", [auth:ROLE_PO], 0],
        ["DELETE", "/campaigns/c-1", [auth:ROLE_ADMIN], 403],
        // New Post / Current Posts writes: PO and Marketing only (CAMPAIGN_EDITORS).
        ["PATCH", "/campaigns/c-1", [], 403],
        ["PATCH", "/campaigns/c-1", [auth:ROLE_SLT], 403],
        ["PATCH", "/campaigns/c-1", [auth:ROLE_PO], 0],
        ["PATCH", "/campaigns/c-1", [auth:ROLE_MARKETING], 0],
        ["DELETE", "/campaigns/c-1", [], 403],
        ["DELETE", "/campaigns/c-1", [auth:ROLE_SLT], 403],
        ["DELETE", "/campaigns/c-1", [auth:ROLE_PO], 0],
        ["DELETE", "/campaigns/c-1", [auth:ROLE_MARKETING], 0],
        ["POST", "/po/external-shares/x-1/approve", [auth:ROLE_MARKETING], 403],
        ["POST", "/po/external-shares/x-1/approve", [auth:ROLE_PO], 0],
        ["POST", "/po/points/adjustments", [auth:ROLE_ADMIN], 403],
        ["PUT", "/admin/settings", [auth:ROLE_PO], 403],
        ["PUT", "/admin/settings", [auth:ROLE_ADMIN], 0],
        ["GET", "/reports/participation", [auth:ROLE_ADMIN], 403],
        ["GET", "/reports/participation", [auth:ROLE_SLT], 0],
        ["GET", "/team/emp-9/history", [], 0],
        ["GET", "/not-in-matrix", [auth:ROLE_ADMIN, auth:ROLE_PO], 403],
        ["GET", "/po/dashboard", ["amplify_po_typo", "Admins"], 403]
    ];
    _ = takeDenials();
    int expectedDenials = 0;
    foreach [string, string, string[], int] [method, path, groups, expected] in cases {
        http:Response res = check call(method, path, check mint(groupsClaim(...groups)));
        if expected == 0 {
            // Past the interceptor: no 401, and no interceptor 403 (a use-case 403 such as TEAM_SCOPE is fine).
            boolean interceptorDenied = res.statusCode == 403
                && [ROLE_NOT_PERMITTED, ROUTE_NOT_PERMITTED].indexOf(check codeOf(res)) !is ();
            test:assertTrue(res.statusCode != 401 && !interceptorDenied,
                    string `${method} ${path} as ${groups.toString()} got ${res.statusCode}`);
        } else {
            test:assertEquals(res.statusCode, expected, string `${method} ${path} as ${groups.toString()}`);
        }
        if expected == 403 {
            expectedDenials += 1;
            test:assertEquals(res.getContentType(), "application/problem+json");
        }
    }
    store:AuditEntry[] audit = takeDenials();
    test:assertEquals(audit.length(), expectedDenials);
    test:assertEquals(audit[0].actorId, "emp-0001");
    test:assertEquals(audit[0].entityId, "GET /po/dashboard");
    test:assertEquals(audit[0].reason, "ROLE_NOT_PERMITTED");
}

@test:Config
function testMissingGroupsClaimIsPlainEmployee() returns error? {
    http:Response res = check call("GET", "/po/dashboard", check mint({groups: ()}));
    test:assertEquals(res.statusCode, 403);
    res = check call("GET", "/me", check mint({groups: ()}));
    test:assertEquals(res.statusCode, 200);
}

@test:Config
function testMatrixHelpers() {
    test:assertEquals(auth:knownRoles("amplify_po, amplify_admin amplify_po"), [auth:ROLE_PO, auth:ROLE_ADMIN]);
    test:assertEquals(auth:knownRoles(["amplify_slt", 42, "other"]), [auth:ROLE_SLT]);
    test:assertEquals(auth:knownRoles(()), []);
    string[] po = auth:capabilities([auth:ROLE_PO]);
    test:assertTrue(po.indexOf("team.history.read_any") !is ());
    test:assertTrue(po.indexOf("campaigns.read_any_status") !is ());
    test:assertTrue(po.indexOf("admin.settings") is ());
    string[] emp = auth:capabilities([]);
    test:assertTrue(emp.indexOf("shares.create") !is ());
    test:assertTrue(emp.indexOf("campaigns.manage") is ());
    test:assertTrue(auth:capabilities([auth:ROLE_MARKETING]).indexOf("campaigns.manage") !is ());
    // Every route row names a capability and a known method.
    foreach auth:Rule rule in auth:ACTIVITY_MATRIX {
        test:assertTrue(["GET", "POST", "PATCH", "PUT", "DELETE"].indexOf(rule.method) !is (), rule.path);
        test:assertTrue(rule.allowed.length() > 0 && rule.capability.length() > 0, rule.path);
    }
}

// ---- GET /me --------------------------------------------------------------------------------------

@test:Config
function testMeUpsertsEmployeeAndReportsCapabilities() returns error? {
    http:Response res = check call("GET", "/me", check mint(groupsClaim(auth:ROLE_MARKETING)));
    test:assertEquals(res.statusCode, 200);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.employee.email, "ada.lovelace@wso2.com");
    test:assertEquals(check body.employee.display_name, "Ada Lovelace");
    test:assertEquals(check body.roles, [auth:ROLE_MARKETING]);
    json[] caps = check (check body.capabilities).ensureType();
    test:assertTrue(caps.indexOf("campaigns.manage") !is ());
    test:assertTrue(caps.indexOf("po.dashboard") is ());
    test:assertEquals(check body.linkedin.status, "NOT_CONNECTED");
    test:assertEquals(check body.linkedin.expires_at, ());
    test:assertTrue(fakeEmployees.findById("emp-0001") is record {});
}

@test:Config
function testMeReportsLinkedInStatus() returns error? {
    time:Utc now = time:utcNow();
    time:Utc expires = types:addDays(now, 30);
    fakeConnections.put({
        employeeId: "emp-0002",
        provider: types:LINKEDIN,
        memberUrn: "urn:li:person:abc",
        providerApi: types:SHARE_ON_LINKEDIN,
        scopes: ["w_member_social"],
        currentToken: {tokenId: "t-1", issuedOn: "2026-10-16"},
        accessExpiresAt: expires,
        connectedAt: now,
        revokedAt: (),
        removedAt: (),
        lastRemindedAt: (),
        version: 1
    });
    http:Response res = check call("GET", "/me", check mint({sub: "emp-0002", email: "grace@wso2.com", name: ()}));
    test:assertEquals(res.statusCode, 200);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.employee.display_name, "grace");
    test:assertEquals(check body.linkedin.status, "ACTIVE");
    test:assertEquals(check body.linkedin.expires_at, time:utcToString(expires));
}

// ---- Dev-only local signing (ADR-023) ------------------------------------------------------------

@test:Config
function testDevSwitchIsRefusedOutsideLocal() {
    test:assertTrue(checkDevSwitch("prod", true, "amplify-local-dev", TEST_ISSUER) is error);
    test:assertTrue(checkDevSwitch("dev", true, "amplify-local-dev", TEST_ISSUER) is error);
    test:assertTrue(checkDevSwitch("local", true, TEST_ISSUER, TEST_ISSUER) is error);
    test:assertTrue(checkDevSwitch("local", true, " ", TEST_ISSUER) is error);
    test:assertTrue(checkDevSwitch("local", true, "amplify-local-dev", TEST_ISSUER) is ());
    test:assertTrue(checkDevSwitch("prod", false, "", TEST_ISSUER) is ());
}

@test:Config
function testDevTrustOnlyAcceptsDevKeysForDevIssuer() returns error? {
    auth:JwksCache jwks = check new ({url: "http://localhost:9591/jwks"});
    auth:VerifierConfig config = {issuer: TEST_ISSUER, audiences: [TEST_AUDIENCE]};
    auth:Jwk devKey = check rogueJwk.ensureType();
    auth:TokenVerifier withDev = new (jwks, config, {issuer: "amplify-local-dev", keys: [devKey]});
    auth:TokenVerifier withoutDev = new (jwks, config);
    crypto:PrivateKey local = check rogueKey.ensureType();

    string devToken = check mint({iss: "amplify-local-dev"}, key = local);
    auth:Principal principal = check withDev.verify(devToken);
    test:assertEquals(principal.issuer, "amplify-local-dev");
    test:assertTrue(withoutDev.verify(devToken) is auth:AuthError, "dev token accepted with the switch off");
    // A dev-issuer token signed by the gateway key, and a gateway token signed by the dev key, both fail.
    test:assertTrue(withDev.verify(check mint({iss: "amplify-local-dev"})) is auth:AuthError);
    test:assertTrue(withDev.verify(check mint(key = local)) is auth:AuthError);
}

// ---- JWKS outage: keep serving with cached keys (M9) ---------------------------------------------

@test:Config {
    dependsOn: [testMissingTokenIs401, testInvalidTokensAre401, testUnsignedTokenIs401, testActivityMatrixSample,
        testMissingGroupsClaimIsPlainEmployee, testMeUpsertsEmployeeAndReportsCapabilities, testMeReportsLinkedInStatus,
        testDevTrustOnlyAcceptsDevKeysForDevIssuer]
}
function testJwksOutageServesCachedKeys() returns error? {
    http:Response warm = check call("GET", "/me", check mint());
    test:assertEquals(warm.statusCode, 200);
    setJwksDown(true);
    do {
        runtime:sleep(1.2); // past jwksRefreshSeconds, so the next call tries (and fails) a refresh
        http:Response res = check call("GET", "/me", check mint());
        test:assertEquals(res.statusCode, 200, "cached keys should keep serving while the IdP is down");

        auth:JwksCache cold = check new ({url: "http://localhost:9591/jwks"});
        auth:Jwk[]|auth:AuthError keys = cold.keysFor(TEST_KID);
        test:assertTrue(keys is auth:AuthError && keys.detail().code == auth:KEYS_UNAVAILABLE);
    } on fail error e {
        setJwksDown(false);
        return e;
    }
    setJwksDown(false);
}
