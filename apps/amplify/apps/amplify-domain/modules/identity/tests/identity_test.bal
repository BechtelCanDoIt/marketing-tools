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

import amplify_common.types;

import ballerina/test;
import ballerina/time;

final time:Utc T0 = [1790000000, 0];

@test:Config
function firstSeenStaysLastSeenMoves() returns error? {
    Employee first = check recordSeen((), {sub: "emp-1", email: "Avery.Mock@WSO2.com"}, T0);
    test:assertEquals(first.email, "avery.mock@wso2.com");
    test:assertEquals(first.displayName, "avery.mock", "falls back to the email local part");
    Employee later = check recordSeen(first, {sub: "emp-1", email: "avery.mock@wso2.com", name: "Avery Mock"},
            types:addDays(T0, 1));
    test:assertEquals(later.firstSeenAt, T0);
    test:assertEquals(later.lastSeenAt, types:addDays(T0, 1));
    test:assertEquals(later.displayName, "Avery Mock");
}

@test:Config
function badClaimsAreRejected() {
    Employee|types:DomainError noSub = recordSeen((), {sub: " ", email: "a@wso2.com"}, T0);
    test:assertTrue(noSub is types:DomainError);
    Employee|types:DomainError badEmail = recordSeen((), {sub: "e", email: "nope"}, T0);
    test:assertTrue(badEmail is types:DomainError);
}
