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

import ballerina/time;

# Records an authenticated call: creates the employee on first sight, then refreshes name, email and
# `lastSeenAt`. `firstSeenAt` never moves.
#
# + existing - Stored employee, if any
# + claims - Token claims
# + now - Current time
# + return - The employee to upsert, or a value-object error
public isolated function recordSeen(Employee? existing, TokenClaims claims, time:Utc now) returns Employee|types:DomainError {
    types:EmployeeId employeeId = check types:parseEmployeeId(claims.sub);
    string email = check types:parseEmail(claims.email);
    string displayName = types:trimToNil(claims.name) ?: re `@`.split(email)[0];
    return {
        employeeId,
        email,
        displayName,
        firstSeenAt: existing is () ? now : existing.firstSeenAt,
        lastSeenAt: now
    };
}
