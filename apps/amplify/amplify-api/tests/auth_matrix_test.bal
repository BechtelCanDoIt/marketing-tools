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

// Auth matrix (plan M11): generated from `auth:ACTIVITY_MATRIX`, so a new route is covered the day it is
// added. Every route × {no token, employee, PO, marketing, SLT, admin}: no token → 401 `TOKEN_MISSING`;
// a caller whose roles don't reach the route → 403 `ROLE_NOT_PERMITTED` plus a `DENIED` audit row; a
// caller who is allowed → never 401/403 (the use case may still answer 400/404/409/503 on fake data).
// Path parameters use the caller's own id where the use case checks ownership (`/team/{employeeId}`).

import amplify_api.auth;

import ballerina/http;
import ballerina/test;

type Caller record {|
    string label;
    string sub;
    string[] groups;
    auth:Audience column;
|};

final Caller[] & readonly MATRIX_CALLERS = [
    {label: "employee", sub: "mx-emp", groups: [], column: auth:EMP},
    {label: "po", sub: "mx-po", groups: [auth:ROLE_PO], column: auth:PO},
    {label: "marketing", sub: "mx-mkt", groups: [auth:ROLE_MARKETING], column: auth:MKT},
    {label: "slt", sub: "mx-slt", groups: [auth:ROLE_SLT], column: auth:SLT},
    {label: "admin", sub: "mx-adm", groups: [auth:ROLE_ADMIN], column: auth:ADM}
];

function matrixPath(string template, string sub) returns string =>
    re `\{[^}]+\}`.replaceAll(re `\{employeeId\}`.replaceAll(template, sub), SAMPLE_UUID);

// Independent of `auth:isAllowed`: a caller reaches a route when the row lists its column or EMP (every
// role also holds the employee column).
function opens(auth:Rule rule, Caller caller) returns boolean {
    foreach auth:Audience a in rule.allowed {
        if a == caller.column || a == "EMP" {
            return true;
        }
    }
    return false;
}

@test:Config
function testEveryRouteAgainstTheActivityMatrix() returns error? {
    setDbUp(true);
    _ = takeDenials();
    int checks = 0;
    string[] failures = [];
    foreach auth:Rule rule in auth:ACTIVITY_MATRIX {
        // No token.
        http:Response anon = check api->execute(rule.method, matrixPath(rule.path, "anon"),
                rule.method == "GET" ? () : {});
        checks += 1;
        if anon.statusCode != 401 || check codeIn(anon) != auth:TOKEN_MISSING {
            failures.push(string `${rule.method} ${rule.path} no token -> ${anon.statusCode}`);
        }
        foreach Caller caller in MATRIX_CALLERS {
            string token = check mint({sub: caller.sub, email: caller.sub + "@wso2.com", name: caller.label,
                groups: caller.groups});
            http:Response res = check send(rule.method, matrixPath(rule.path, caller.sub), {}, token,
                    {"Idempotency-Key": string `mx-${caller.sub}-${checks}`});
            checks += 1;
            // Every role also holds the employee column (audiences() always adds EMP).
            boolean allowed = opens(rule, caller);
            if allowed {
                if res.statusCode == 401 || res.statusCode == 403 {
                    failures.push(string `${rule.method} ${rule.path} ${caller.label} allowed but got ${res.statusCode}`);
                }
            } else if res.statusCode != 403 || check codeIn(res) != ROLE_NOT_PERMITTED {
                failures.push(string `${rule.method} ${rule.path} ${caller.label} expected 403 got ${res.statusCode}`);
            }
        }
    }
    test:assertEquals(failures, [], string `auth matrix mismatches (${checks} checks)`);
    test:assertEquals(checks, auth:ACTIVITY_MATRIX.length() * (MATRIX_CALLERS.length() + 1));

    int expectedDenials = 0;
    foreach auth:Rule rule in auth:ACTIVITY_MATRIX {
        foreach Caller caller in MATRIX_CALLERS {
            if !opens(rule, caller) {
                expectedDenials += 1;
            }
        }
    }
    test:assertTrue(expectedDenials > 0);
    test:assertTrue(takeDenials().length() >= expectedDenials, "every 403 writes a DENIED audit row");
}
