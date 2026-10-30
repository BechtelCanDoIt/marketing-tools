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


import ballerina/test;

@test:Config
function noveraClientRefusesPlainHttpUnlessTheLocalFlagIsSet() {
    string url = "http://host.docker.internal:3003/internal/notifications";
    NoveraClient|error strict = new (url, "http://host.docker.internal:3003/token", "mock", "mock", [], 5);
    test:assertTrue(strict is error);
    NoveraClient|error local = new (url, "http://host.docker.internal:3003/token", "mock", "mock", [], 5,
        allowInsecureHttp = true);
    test:assertTrue(local is NoveraClient);
    // The flag never relaxes an https check, and never accepts another scheme.
    test:assertTrue((new NoveraClient("ftp://x.example/n", "https://x.example/t", "a", "b", [], 5,
        allowInsecureHttp = true)) is error);
}

@test:Config
function noveraTokenEndpointDownIsARetryableUnavailableNotAStartUpFailure() {
    // Built without any network call, so a Novera outage can't stop amplify-jobs from starting.
    NoveraClient|error built = new ("http://127.0.0.1:1/internal/notifications", "http://127.0.0.1:1/token", "mock",
        "mock", [], 2, allowInsecureHttp = true);
    test:assertTrue(built is NoveraClient);
    if built is NoveraClient {
        NoveraError? result = built.notify({'source: "amplify", title: "T", subtitle: "S", body: "B",
            button: {url: "https://one.wso2.com", label: "Amplify"}}, ());
        test:assertTrue(result is NoveraError);
        if result is NoveraError {
            test:assertEquals(result.detail().code, "UNAVAILABLE");
            test:assertTrue(result.detail().retryable);
        }
    }
}
