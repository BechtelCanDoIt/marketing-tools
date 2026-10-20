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

// Shared kernel `identity.employee`. Publishes no events (no events.bal); erasure is deferred (C3, ADR-016).

import amplify_common.types;

import ballerina/time;

# Employee (`identity.employee`), upserted from the access token on authenticated calls (ADR-009).
public type Employee record {|
    # Asgardeo `sub`
    types:EmployeeId employeeId;
    # Lowercased email (citext in the DB)
    string email;
    # Display name for the leaderboard
    string displayName;
    # First authenticated call
    time:Utc firstSeenAt;
    # Latest authenticated call
    time:Utc lastSeenAt;
|};

# Claims taken from the validated access token.
public type TokenClaims record {|
    # `sub`
    string sub;
    # `email`
    string email;
    # Display name; falls back to the email's local part
    string? name = ();
|};

# Persistence port for `identity.employee`.
public type EmployeeRepository isolated object {
    # Finds an employee.
    #
    # + employeeId - Asgardeo `sub`
    # + return - The employee, `()` if never seen, or an error
    public isolated function findById(types:EmployeeId employeeId) returns Employee|error?;

    # Inserts or refreshes an employee (`recordSeen` result). `firstSeenAt` never moves on update.
    #
    # + employee - Employee
    # + return - An error, for example when the email already belongs to another employee
    public isolated function upsert(Employee employee) returns error?;
};
