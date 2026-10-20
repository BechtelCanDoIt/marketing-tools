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

import ballerina/http;
import ballerina/test;

final http:Client testClient = check new ("http://localhost:9091");

@test:Config
function testHealthReturnsUp() returns error? {
    types:HealthStatus body = check testClient->get("/health");
    test:assertEquals(body, {component: COMPONENT, status: types:UP});
}

@test:Config
function testRunsWithoutDatabaseIs503() returns error? {
    http:Response res = check testClient->post("/runs", ());
    test:assertEquals(res.statusCode, http:STATUS_SERVICE_UNAVAILABLE);
}

@test:Config
function testPartitionMaintenanceWithoutDatabaseIs503() returns error? {
    http:Response res = check testClient->post("/maintenance/partitions", ());
    test:assertEquals(res.statusCode, http:STATUS_SERVICE_UNAVAILABLE);
}

@test:Config
function testRebuildRecognitionWithoutDatabaseIs503() returns error? {
    http:Response res = check testClient->post("/maintenance/rebuild-recognition", ());
    test:assertEquals(res.statusCode, http:STATUS_SERVICE_UNAVAILABLE);
}
