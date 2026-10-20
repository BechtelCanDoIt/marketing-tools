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

import ballerina/lang.regexp;
import ballerina/time;

// ---- Derived status -------------------------------------------------------------------------------

# Campaign status from its facts and the clock, as `campaign.campaign_v` computes it.
#
# + campaign - Campaign
# + now - Current time
# + return - `ARCHIVED` if archived; `SCHEDULED` before `opensAt`; `OPEN` before `closesAt`; else `CLOSED`
public isolated function campaignStatus(Campaign campaign, time:Utc now) returns CampaignStatus {
    if campaign.archivedAt !is () {
        return ARCHIVED;
    }
    if types:isBefore(now, campaign.opensAt) {
        return SCHEDULED;
    }
    if types:isBefore(now, campaign.closesAt) {
        return OPEN;
    }
    return CLOSED;
}

# Whether employees can share the campaign now.
#
# + campaign - Campaign
# + now - Current time
# + return - True while `OPEN`
public isolated function isOpen(Campaign campaign, time:Utc now) returns boolean => campaignStatus(campaign, now) == OPEN;

// ---- Aggregate rules (pure) -----------------------------------------------------------------------

# Builds a new campaign, enforcing its invariants: valid resource URN on the WSO2 page, title and category
# present, HTTPS links, lowercase unique tags, and `closesAt > opensAt` with the C7 default window.
#
# + draft - Input
# + policy - Campaign settings
# + id - New UUIDv7
# + actor - Who registers it
# + now - Current time
# + return - The campaign, or a domain error
public isolated function newCampaign(CampaignDraft draft, CampaignPolicy policy, string id, types:EmployeeId actor,
        time:Utc now) returns Campaign|types:DomainError {
    types:PostUrn resourceUrn = check types:parsePostUrn(draft.resourceUrn);
    types:OrganizationUrn ownerUrn = check types:parseOrganizationUrn(draft.ownerUrn);
    if ownerUrn != policy.wso2OrganizationUrn {
        return types:domainError(types:ERR_NOT_WSO2_RESOURCE, "The post must be on the WSO2 company page");
    }
    string title = check validTitle(draft.title);
    string categoryCode = check validCategory(draft.categoryCode);
    string? resourceUrl = check postLink(draft.resourceUrl, policy.postLinkOrigins);
    string? imageUrl = check optionalHttps(draft.imageUrl, "Image URL");
    time:Utc opensAt = draft.opensAt ?: now;
    time:Utc closesAt = draft.closesAt ?: types:addDays(opensAt, policy.defaultWindowDays);
    check validWindow(opensAt, closesAt);
    return {
        id,
        provider: types:LINKEDIN,
        resourceUrn,
        resourceType: types:resourceTypeOf(resourceUrn),
        ownerUrn,
        resourceUrl,
        title,
        summary: types:trimToNil(draft.summary),
        imageUrl,
        categoryCode,
        isPriority: draft.isPriority,
        tags: check normalizeTags(draft.tags),
        opensAt,
        closesAt,
        archivedAt: (),
        createdBy: actor,
        createdAt: now,
        updatedAt: now,
        version: 1
    };
}

# Applies an edit. Archived campaigns can't change; the window rule is re-checked.
#
# + campaign - Current campaign
# + patch - Changes
# + now - Current time
# + return - The changed campaign (version bumped), or a domain error
public isolated function applyPatch(Campaign campaign, CampaignPatch patch, time:Utc now) returns Campaign|types:DomainError {
    if campaign.archivedAt !is () {
        return types:domainError(types:ERR_CAMPAIGN_ARCHIVED, "An archived campaign can't be changed");
    }
    Campaign changed = campaign.clone();
    string? title = patch.title;
    if title is string {
        changed.title = check validTitle(title);
    }
    if patch.summary !is () {
        changed.summary = types:trimToNil(patch.summary);
    }
    if patch.imageUrl !is () {
        changed.imageUrl = check optionalHttps(patch.imageUrl, "Image URL");
    }
    string? categoryCode = patch.categoryCode;
    if categoryCode is string {
        changed.categoryCode = check validCategory(categoryCode);
    }
    boolean? isPriority = patch.isPriority;
    if isPriority is boolean {
        changed.isPriority = isPriority;
    }
    string[]? tags = patch.tags;
    if tags is string[] {
        changed.tags = check normalizeTags(tags);
    }
    changed.opensAt = patch.opensAt ?: campaign.opensAt;
    changed.closesAt = patch.closesAt ?: campaign.closesAt;
    check validWindow(changed.opensAt, changed.closesAt);
    changed.updatedAt = now;
    changed.version = campaign.version + 1;
    return changed;
}

# Archives a campaign (the "Delete" action). Points and ledger references already earned stay.
#
# + campaign - Current campaign
# + now - Current time
# + return - The archived campaign, or `CAMPAIGN_ARCHIVED` if it already is
public isolated function archive(Campaign campaign, time:Utc now) returns Campaign|types:DomainError {
    if campaign.archivedAt !is () {
        return types:domainError(types:ERR_CAMPAIGN_ARCHIVED, "The campaign is already archived");
    }
    Campaign archived = campaign.clone();
    archived.archivedAt = now;
    archived.updatedAt = now;
    archived.version = campaign.version + 1;
    return archived;
}

// ---- Use cases ------------------------------------------------------------------------------------

# Registers a campaign (Save, or Save & Share Now) and queues `CampaignRegistered` for the Club card.
#
# + repo - Campaign repository
# + draft - Input
# + policy - Campaign settings
# + actor - `amplify_marketing` or `amplify_po` caller (role checked by the API layer)
# + shareNow - Save & Share Now
# + now - Current time
# + return - The campaign, `CAMPAIGN_ALREADY_REGISTERED`, another domain error, or a repository error
public isolated function registerCampaign(CampaignRepository repo, CampaignDraft draft, CampaignPolicy policy,
        types:EmployeeId actor, boolean shareNow, time:Utc now) returns Campaign|error {
    Campaign campaign = check newCampaign(draft, policy, types:newUuidV7(), actor, now);
    Campaign? existing = check repo.findByResource(campaign.provider, campaign.resourceUrn);
    if existing is Campaign {
        return types:domainError(types:ERR_CAMPAIGN_ALREADY_REGISTERED, "This post is already a campaign");
    }
    check repo.insert(campaign, [campaignRegisteredEvent(campaign, shareNow)]);
    return campaign;
}

# Edits a campaign.
#
# + repo - Campaign repository
# + id - Campaign id
# + patch - Changes
# + now - Current time
# + return - The changed campaign, `NOT_FOUND`, a domain error, or a repository error
public isolated function updateCampaign(CampaignRepository repo, string id, CampaignPatch patch, time:Utc now)
        returns Campaign|error {
    Campaign current = check findOrFail(repo, id);
    Campaign changed = check applyPatch(current, patch, now);
    check repo.update(changed, current.version);
    return changed;
}

# Archives a campaign.
#
# + repo - Campaign repository
# + id - Campaign id
# + now - Current time
# + return - The archived campaign, `NOT_FOUND`, `CAMPAIGN_ARCHIVED`, or a repository error
public isolated function archiveCampaign(CampaignRepository repo, string id, time:Utc now) returns Campaign|error {
    Campaign current = check findOrFail(repo, id);
    Campaign archived = check archive(current, now);
    check repo.update(archived, current.version);
    return archived;
}

// ---- Helpers --------------------------------------------------------------------------------------

isolated function findOrFail(CampaignRepository repo, string id) returns Campaign|error {
    Campaign? campaign = check repo.findById(id);
    if campaign is () {
        return types:domainError(types:ERR_NOT_FOUND, "Campaign not found");
    }
    return campaign;
}

isolated function validTitle(string raw) returns string|types:DomainError {
    string title = raw.trim();
    if title.length() == 0 || title.length() > TITLE_MAX_LENGTH {
        return types:domainError(types:ERR_INVALID_CAMPAIGN, string `Title must be 1-${TITLE_MAX_LENGTH} characters`);
    }
    return title;
}

isolated function validCategory(string raw) returns string|types:DomainError {
    string code = raw.trim();
    if code.length() == 0 {
        return types:domainError(types:ERR_INVALID_CAMPAIGN, "Category is required");
    }
    return code;
}

# A post link, if given, must use one of the allowed origins. Every employee's card links to it, so a
# foreign host would be a phishing link with WSO2's name on it.
#
# + raw - Link as sent
# + origins - Allowed origins, lowercase `scheme://host[:port]`
# + return - The trimmed link, `()` when none was sent, or `INVALID_CAMPAIGN`
isolated function postLink(string? raw, string[] origins) returns string?|types:DomainError {
    string? value = types:trimToNil(raw);
    if value is () {
        return ();
    }
    string? origin = originOf(value);
    if origin is () || origins.indexOf(origin) is () || value.length() > types:EVIDENCE_URL_MAX_LENGTH {
        return types:domainError(types:ERR_INVALID_CAMPAIGN, "Post URL must be a LinkedIn link");
    }
    return value;
}

# `scheme://host[:port]`, lowercase, or `()` for anything that isn't a plain http(s) URL: no credentials
# (`user@host`), no whitespace.
#
# + url - URL
# + return - The origin, or `()`
isolated function originOf(string url) returns string? {
    if re `.*\s.*`.isFullMatch(url) {
        return ();
    }
    regexp:Groups? g = re `^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)`.findGroups(url);
    if g is () || g.length() < 3 {
        return ();
    }
    regexp:Span? scheme = g[1];
    regexp:Span? authority = g[2];
    if scheme is () || authority is () || authority.substring().includes("@") {
        return ();
    }
    string s = scheme.substring().toLowerAscii();
    if s != "https" && s != "http" {
        return ();
    }
    return string `${s}://${authority.substring().toLowerAscii()}`;
}

isolated function optionalHttps(string? raw, string label) returns string?|types:DomainError {
    string? value = types:trimToNil(raw);
    if value is string && !types:isHttpsUrl(value) {
        return types:domainError(types:ERR_INVALID_CAMPAIGN, string `${label} must be an HTTPS URL`);
    }
    return value;
}

isolated function validWindow(time:Utc opensAt, time:Utc closesAt) returns types:DomainError? {
    if !types:isBefore(opensAt, closesAt) {
        return types:domainError(types:ERR_INVALID_WINDOW, "The campaign must close after it opens");
    }
    return ();
}

# Trims, lowercases and de-duplicates tags, keeping first-seen order.
#
# + raw - Tags as entered
# + return - Normalized tags, or `INVALID_CAMPAIGN` for a tag over the length limit
public isolated function normalizeTags(string[] raw) returns string[]|types:DomainError {
    string[] tags = [];
    foreach string item in raw {
        string tag = item.trim().toLowerAscii();
        if tag.length() == 0 || tags.indexOf(tag) !is () {
            continue;
        }
        if tag.length() > TAG_MAX_LENGTH {
            return types:domainError(types:ERR_INVALID_CAMPAIGN, string `Tags must be at most ${TAG_MAX_LENGTH} characters`);
        }
        tags.push(tag);
    }
    return tags;
}
