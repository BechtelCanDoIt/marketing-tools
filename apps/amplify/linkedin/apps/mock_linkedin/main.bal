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
import mock_linkedin.store;

import ballerina/http;
import ballerina/log;

# Health check for liveness and readiness probes.
@display {
    label: "Mock LinkedIn Health",
    id: "linkedin/mock-health"
}
service /health on apiListener {

    # Reports that the mock is up.
    #
    # + return - Status
    isolated resource function get .() returns map<string> => {status: HEALTH_STATUS_UP};
}

# Admin endpoints for tests: see what the mock has stored, and wipe it between runs.
# Attached only when `enableMockAdmin` is true. Never expose these outside local testing.
@display {
    label: "Mock LinkedIn Admin",
    id: "linkedin/mock-admin"
}
final http:Service mockAdminService = service object {

    # Lists every post the mock holds.
    #
    # + return - Posts, oldest first
    isolated resource function get posts() returns store:Post[] => store:listPosts();

    # Clears tokens, codes, posts, uploads and rate counters.
    #
    # + return - 204
    isolated resource function post reset() returns http:NoContent {
        store:reset();
        log:printInfo("Mock state reset");
        return http:NO_CONTENT;
    }
};

function init() returns error? {
    if enableMockAdmin {
        check apiListener.attach(mockAdminService, MOCK_ADMIN_BASE_PATH);
        log:printInfo("Mock admin endpoints enabled", basePath = MOCK_ADMIN_BASE_PATH);
    }
    log:printInfo("Mock LinkedIn started", apiPort = apiPort, wwwPort = wwwPort);
}
