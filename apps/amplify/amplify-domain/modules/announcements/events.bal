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

// Events S5 publishes.

import amplify_common.events;

import ballerina/time;

# `CampaignAnnounced` once the card is sent (key `outbox.id`).
#
# + announcement - Sent announcement
# + return - Outbox row
public isolated function campaignAnnouncedEvent(Announcement announcement) returns events:OutboxEvent {
    time:Utc? sentAt = announcement.sentAt;
    return events:newCampaignAnnounced({
        campaignId: announcement.campaignId,
        outboxId: announcement.outboxId ?: 0,
        chatMessageName: announcement.chatMessageName ?: "",
        sentAt: sentAt is () ? "" : time:utcToString(sentAt)
    });
}
