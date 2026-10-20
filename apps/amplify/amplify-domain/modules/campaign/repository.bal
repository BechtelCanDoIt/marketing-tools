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

// PostgreSQL implementation of `CampaignRepository` (schema `campaign` only). Aggregate rows, outbox
// rows and the audit row commit in one transaction.

import amplify_common.events;
import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

const string CAMPAIGN_TABLE = "campaign.campaign";

type CampaignRow record {|
    string id;
    string provider;
    string resource_urn;
    string resource_type;
    string owner_urn;
    string? resource_url;
    string title;
    string? summary;
    string? image_url;
    string category_code;
    boolean is_priority;
    time:Utc opens_at;
    time:Utc closes_at;
    time:Utc? archived_at;
    string created_by;
    time:Utc created_at;
    time:Utc updated_at;
    int version;
|};

type TagRow record {|
    string tag;
|};

# `CampaignRepository` over PostgreSQL.
public isolated class PgCampaignRepository {
    *CampaignRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client (DB user `amplify_api`)
    # + actor - Who the writes are for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function findById(string id) returns Campaign|error? {
        CampaignRow|error row = self.db->queryRow(`
            SELECT id::text AS id, provider, resource_urn, resource_type, owner_urn, resource_url, title, summary,
                   image_url, category_code, is_priority, opens_at, closes_at, archived_at, created_by, created_at,
                   updated_at, version
            FROM campaign.campaign WHERE id = CAST(${id} AS uuid)`);
        return self.toCampaign(row);
    }

    public isolated function findByResource(types:Provider provider, types:PostUrn resourceUrn) returns Campaign|error? {
        CampaignRow|error row = self.db->queryRow(`
            SELECT id::text AS id, provider, resource_urn, resource_type, owner_urn, resource_url, title, summary,
                   image_url, category_code, is_priority, opens_at, closes_at, archived_at, created_by, created_at,
                   updated_at, version
            FROM campaign.campaign WHERE provider = ${provider} AND resource_urn = ${resourceUrn}`);
        return self.toCampaign(row);
    }

    public isolated function insert(Campaign campaign, events:OutboxEvent[] outbox) returns error? {
        final readonly & Campaign c = campaign.cloneReadOnly();
        final readonly & events:OutboxEvent[] queued = outbox.cloneReadOnly();
        error? result = store:inTransaction(isolated function () returns error? => self.insertTx(c, queued));
        if result is error && store:isUniqueViolation(result, "campaign_provider_resource_uk") {
            return types:domainError(types:ERR_CAMPAIGN_ALREADY_REGISTERED, "This post is already a campaign");
        }
        return result;
    }

    public isolated function update(Campaign campaign, int expectedVersion) returns error? {
        final readonly & Campaign c = campaign.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.updateTx(c, expectedVersion));
    }

    private isolated function updateTx(Campaign campaign, int expectedVersion) returns error? {
        transaction {
            record {|string title; boolean archived; int version;|}|error old = self.db->queryRow(`
                UPDATE campaign.campaign
                SET title = ${campaign.title}, summary = ${campaign.summary}, image_url = ${campaign.imageUrl},
                    category_code = ${campaign.categoryCode}, is_priority = ${campaign.isPriority},
                    opens_at = CAST(${store:ts(campaign.opensAt)} AS timestamptz), closes_at = CAST(${store:ts(campaign.closesAt)} AS timestamptz),
                    archived_at = CAST(${store:ts(campaign.archivedAt)} AS timestamptz), updated_at = CAST(${store:ts(campaign.updatedAt)} AS timestamptz),
                    version = ${campaign.version}
                WHERE id = CAST(${campaign.id} AS uuid) AND version = ${expectedVersion}
                RETURNING old.title, old.archived_at IS NOT NULL AS archived, old.version`);
            if old is error {
                fail store:isNoRows(old) ? store:versionConflict("campaign") : old;
            }
            check self.replaceTags(campaign);
            string action = campaign.archivedAt is () ? "CampaignUpdated" : "CampaignArchived";
            check store:writeAudit(self.db, store:auditOf(self.actor, action, CAMPAIGN_TABLE, campaign.id,
                    {version: campaign.version, title: campaign.title, archived: campaign.archivedAt !is ()}, (),
                    {version: old.version, title: old.title, archived: old.archived}));
            check commit;
        }
    }

    private isolated function insertTx(Campaign campaign, events:OutboxEvent[] outbox) returns error? {
        transaction {
            _ = check self.db->execute(`
                INSERT INTO campaign.campaign (id, provider, resource_urn, resource_type, owner_urn, resource_url,
                                               title, summary, image_url, category_code, is_priority, opens_at,
                                               closes_at, archived_at, created_by, created_at, updated_at, version)
                VALUES (CAST(${campaign.id} AS uuid), ${campaign.provider}, ${campaign.resourceUrn},
                        ${campaign.resourceType}, ${campaign.ownerUrn}, ${campaign.resourceUrl}, ${campaign.title},
                        ${campaign.summary}, ${campaign.imageUrl}, ${campaign.categoryCode}, ${campaign.isPriority},
                        CAST(${store:ts(campaign.opensAt)} AS timestamptz), CAST(${store:ts(campaign.closesAt)} AS timestamptz), CAST(${store:ts(campaign.archivedAt)} AS timestamptz), ${campaign.createdBy},
                        CAST(${store:ts(campaign.createdAt)} AS timestamptz), CAST(${store:ts(campaign.updatedAt)} AS timestamptz), ${campaign.version})`);
            check self.replaceTags(campaign);
            _ = check store:writeOutbox(self.db, outbox, self.actor.correlationId);
            check store:writeAudit(self.db, store:auditOf(self.actor, events:CAMPAIGN_REGISTERED, CAMPAIGN_TABLE,
                    campaign.id, {resourceUrn: campaign.resourceUrn, title: campaign.title}));
            check commit;
        }
    }

    private isolated transactional function replaceTags(Campaign campaign) returns error? {
        _ = check self.db->execute(`DELETE FROM campaign.campaign_tag WHERE campaign_id = CAST(${campaign.id} AS uuid)`);
        foreach string tag in campaign.tags {
            _ = check self.db->execute(`
                INSERT INTO campaign.campaign_tag (campaign_id, tag) VALUES (CAST(${campaign.id} AS uuid), ${tag})`);
        }
    }

    private isolated function toCampaign(CampaignRow|error row) returns Campaign|error? {
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        stream<TagRow, error?> rows = self.db->query(
                `SELECT tag FROM campaign.campaign_tag WHERE campaign_id = CAST(${row.id} AS uuid) ORDER BY tag`);
        string[] tags = check from TagRow t in rows
            select t.tag;
        return {
            id: row.id,
            provider: check row.provider.ensureType(),
            resourceUrn: row.resource_urn,
            resourceType: check row.resource_type.ensureType(),
            ownerUrn: row.owner_urn,
            resourceUrl: row.resource_url,
            title: row.title,
            summary: row.summary,
            imageUrl: row.image_url,
            categoryCode: row.category_code,
            isPriority: row.is_priority,
            tags,
            opensAt: row.opens_at,
            closesAt: row.closes_at,
            archivedAt: row.archived_at,
            createdBy: row.created_by,
            createdAt: row.created_at,
            updatedAt: row.updated_at,
            version: row.version
        };
    }
}
