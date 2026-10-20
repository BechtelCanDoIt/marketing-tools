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

// PostgreSQL implementation of `EmployeeRepository` (schema `identity`).

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

type EmployeeRow record {|
    string employee_id;
    string email;
    string display_name;
    time:Utc first_seen_at;
    time:Utc last_seen_at;
|};

# `EmployeeRepository` over PostgreSQL.
public isolated class PgEmployeeRepository {
    *EmployeeRepository;

    private final postgresql:Client db;

    # + db - Shared client (`amplify_api`)
    public isolated function init(postgresql:Client db) {
        self.db = db;
    }

    public isolated function findById(types:EmployeeId employeeId) returns Employee|error? {
        EmployeeRow|error row = self.db->queryRow(`
            SELECT employee_id, email::text AS email, display_name, first_seen_at, last_seen_at
            FROM identity.employee WHERE employee_id = ${employeeId}`);
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        return {
            employeeId: row.employee_id,
            email: row.email,
            displayName: row.display_name,
            firstSeenAt: row.first_seen_at,
            lastSeenAt: row.last_seen_at
        };
    }

    public isolated function upsert(Employee e) returns error? {
        _ = check self.db->execute(`
            INSERT INTO identity.employee (employee_id, email, display_name, first_seen_at, last_seen_at)
            VALUES (${e.employeeId}, ${e.email}, ${e.displayName}, CAST(${store:ts(e.firstSeenAt)} AS timestamptz), CAST(${store:ts(e.lastSeenAt)} AS timestamptz))
            ON CONFLICT (employee_id) DO UPDATE
                SET email = EXCLUDED.email, display_name = EXCLUDED.display_name,
                    last_seen_at = GREATEST(identity.employee.last_seen_at, EXCLUDED.last_seen_at)`);
    }
}
