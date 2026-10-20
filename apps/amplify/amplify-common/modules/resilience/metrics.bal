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

// Breaker state as a metric (plan M9): gauge `amplify_breaker_state{component, dependency}` = 0 closed,
// 1 half-open, 2 open, published through Ballerina observability (Prometheus when metrics are enabled;
// Choreo's observability picks it up). Alert on `amplify_breaker_state == 2`.

import ballerina/observe;

# Gauge name.
public const string BREAKER_METRIC = "amplify_breaker_state";

# Gauge value for a state name; anything that isn't a breaker state (`NOT_CONFIGURED`) is -1.
#
# + state - `CLOSED`, `HALF_OPEN`, `OPEN` or another label
# + return - 0, 1, 2 or -1
public isolated function breakerStateValue(string state) returns float =>
    state == "CLOSED" ? 0.0 : state == "HALF_OPEN" ? 1.0 : state == "OPEN" ? 2.0 : -1.0;

# Sets `amplify_breaker_state` for each dependency of a component (registers the gauge on first use).
# Never fails the caller: a metrics problem is not a reason to fail a request or a run.
#
# + component - `amplify-api` or `amplify-jobs`
# + states - State by dependency
public isolated function exportBreakerStates(string component, map<string> states) {
    foreach [string, string] [dependency, state] in states.entries() {
        map<string> tags = {component, dependency};
        observe:Gauge gauge;
        observe:Counter|observe:Gauge? existing = observe:lookupMetric(BREAKER_METRIC, tags);
        if existing is observe:Gauge {
            gauge = existing;
        } else {
            gauge = new (BREAKER_METRIC, "Circuit breaker state: 0 closed, 1 half-open, 2 open, -1 not configured",
                tags);
            error? registered = gauge.register();
            if registered is error {
                // Someone registered it between the lookup and here; use theirs.
                observe:Counter|observe:Gauge? again = observe:lookupMetric(BREAKER_METRIC, tags);
                if again is observe:Gauge {
                    gauge = again;
                }
            }
        }
        gauge.setValue(breakerStateValue(state));
    }
}

# Current gauge value, or `()` when not exported yet (tests, `/ready`).
#
# + component - Component
# + dependency - Dependency
# + return - The value or `()`
public isolated function exportedBreakerValue(string component, string dependency) returns float? {
    observe:Counter|observe:Gauge? g = observe:lookupMetric(BREAKER_METRIC, {component, dependency});
    return g is observe:Gauge ? g.getValue() : ();
}
