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

// Team rosters from the people directory (D13): grouping by sub-team with the team as fallback, and the
// viewer's roster lookup.

import ballerina/test;

final DirectoryRecord[] & readonly DIRECTORY = [
    {workEmail: "Ada@WSO2.com", team: "Customer Success", subTeam: "Forward Deployed Engineering"},
    {workEmail: "grace@wso2.com", team: "Customer Success", subTeam: "Forward Deployed Engineering"},
    {workEmail: "linus@wso2.com", team: "Customer Success", subTeam: "Support"},
    {workEmail: "ken@wso2.com", team: "Marketing", subTeam: ()},
    {workEmail: "dennis@wso2.com", team: "Marketing", subTeam: "  "},
    // Same sub-team name under another team: a different team.
    {workEmail: "barbara@wso2.com", team: "Engineering", subTeam: "Support"},
    // No team at all: left out.
    {workEmail: "nobody@wso2.com", team: (), subTeam: ()}
];

@test:Config
function testRosterGroupsBySubTeam() {
    Roster? roster = rosterFrom(indexDirectory(DIRECTORY), "grace@wso2.com");
    test:assertEquals(roster, {teamName: "Forward Deployed Engineering", emails: ["ada@wso2.com", "grace@wso2.com"]});
}

@test:Config
function testRosterFallsBackToTeam() {
    Roster? roster = rosterFrom(indexDirectory(DIRECTORY), "ken@wso2.com");
    test:assertEquals(roster, {teamName: "Marketing", emails: ["ken@wso2.com", "dennis@wso2.com"]});
}

@test:Config
function testRosterKeepsSameNamedSubTeamsApart() {
    DirectoryIndex index = indexDirectory(DIRECTORY);
    test:assertEquals(rosterFrom(index, "linus@wso2.com")?.emails, ["linus@wso2.com"]);
    test:assertEquals(rosterFrom(index, "barbara@wso2.com")?.emails, ["barbara@wso2.com"]);
}

@test:Config
function testRosterMatchesEmailIgnoringCase() {
    test:assertEquals(rosterFrom(indexDirectory(DIRECTORY), " ADA@wso2.COM ")?.teamName,
            "Forward Deployed Engineering");
}

@test:Config
function testNoRosterWithoutTeamOrDirectoryRow() {
    DirectoryIndex index = indexDirectory(DIRECTORY);
    test:assertEquals(rosterFrom(index, "nobody@wso2.com"), ());
    test:assertEquals(rosterFrom(index, "stranger@wso2.com"), ());
}
