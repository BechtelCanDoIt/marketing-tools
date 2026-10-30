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
function testRunwayAlertsWhenShortOrUnknown() {
    test:assertFalse(isRunwayAlerting(14, 3));
    test:assertFalse(isRunwayAlerting(3, 3), "exactly at the threshold is not short");
    test:assertTrue(isRunwayAlerting(2, 3));
    test:assertTrue(isRunwayAlerting(0, 3), "only today is left");
    test:assertTrue(isRunwayAlerting(-1, 3), "the newest partition is already behind us");
    test:assertTrue(isRunwayAlerting((), 3), "no partition at all");
}

@test:Config
function testRunwayReportOmitsTheDaysWhenThereIsNoPartition() {
    test:assertEquals(toTokenPartitionReport(14, 3), {daysAhead: 14, alerting: false});
    test:assertEquals(toTokenPartitionReport(1, 3), {daysAhead: 1, alerting: true});
    test:assertEquals(toTokenPartitionReport((), 3), {alerting: true});
}

@test:Config
function testReadinessCarriesTheRunwayOnlyWhenItWasRead() {
    test:assertTrue(readiness(true, {}, false).tokenPartitions is ());
    TokenPartitionReport short = {daysAhead: 1, alerting: true};
    ReadyReport report = readiness(true, {}, false, (), short);
    test:assertEquals(report.tokenPartitions, short);
    // A short runway is an alert, never a reason to take the worker out of rotation.
    test:assertEquals(report.status, readiness(true, {}, false).status);
}
