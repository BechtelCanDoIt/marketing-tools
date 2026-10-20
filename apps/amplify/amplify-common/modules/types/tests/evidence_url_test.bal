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

function normalizationCases() returns map<[string, string]> => {
    "lowercaseSchemeAndHost": ["HTTPS://WWW.Example.COM/Blog/Post", "https://www.example.com/Blog/Post"],
    "stripTrailingSlash": ["https://example.com/blog/post/", "https://example.com/blog/post"],
    "stripRootSlash": ["https://example.com/", "https://example.com"],
    "stripUtm": ["https://example.com/p?utm_source=x&utm_Medium=y&id=7", "https://example.com/p?id=7"],
    "stripClickIds": ["https://example.com/p?fbclid=1&gclid=2&trk=3&trackingId=4&a=b", "https://example.com/p?a=b"],
    "sortQuery": ["https://example.com/p?z=1&a=2&m=3", "https://example.com/p?a=2&m=3&z=1"],
    "dropFragment": ["https://example.com/p#comments", "https://example.com/p"],
    "dropDefaultPort": ["https://example.com:443/p", "https://example.com/p"],
    "keepOtherPort": ["https://example.com:8443/p", "https://example.com:8443/p"],
    "trailingDotHost": ["https://example.com./p", "https://example.com/p"],
    "onlyTrackingQuery": ["https://medium.com/@wso2/post-1a2b/?utm_campaign=x", "https://medium.com/@wso2/post-1a2b"],
    "trimmed": ["  https://example.com/p  ", "https://example.com/p"]
};

@test:Config {dataProvider: normalizationCases}
function evidenceUrlIsNormalized(string raw, string expected) returns error? {
    EvidenceUrl url = check parseEvidenceUrl(raw);
    test:assertEquals(url.normalized, expected);
    test:assertEquals(url.submitted, raw.trim());
}

@test:Config
function sameLinkTypedTwoWaysNormalizesToOneKey() returns error? {
    EvidenceUrl a = check parseEvidenceUrl("https://www.LinkedIn.com/posts/avery_wso2-activity-7123456789-AbCd/?utm_source=share&utm_medium=member_desktop");
    EvidenceUrl b = check parseEvidenceUrl("https://www.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd");
    test:assertEquals(a.normalized, b.normalized);
}

function rejectedUrls() returns map<[string, string]> => {
    "http": ["http://example.com/p", ERR_EVIDENCE_URL_NOT_HTTPS],
    "ftp": ["ftp://example.com/p", ERR_EVIDENCE_URL_NOT_HTTPS],
    "javascript": ["javascript:alert(1)", ERR_EVIDENCE_URL_NOT_HTTPS],
    "noScheme": ["example.com/p", ERR_EVIDENCE_URL_NOT_HTTPS],
    "blank": ["   ", ERR_INVALID_EVIDENCE_URL],
    "credentials": ["https://user:pass@example.com/p", ERR_EVIDENCE_URL_CREDENTIALS],
    "userOnly": ["https://user@example.com/p", ERR_EVIDENCE_URL_CREDENTIALS],
    "ipv4": ["https://10.0.0.1/admin", ERR_EVIDENCE_URL_IP_HOST],
    "ipv4Public": ["https://8.8.8.8", ERR_EVIDENCE_URL_IP_HOST],
    "ipv6": ["https://[::1]/p", ERR_EVIDENCE_URL_IP_HOST],
    "decimalIp": ["https://2130706433/p", ERR_EVIDENCE_URL_IP_HOST],
    "localhost": ["https://localhost/p", ERR_INVALID_EVIDENCE_URL],
    "badPort": ["https://example.com:99999/p", ERR_INVALID_EVIDENCE_URL],
    "space": ["https://example.com/a b", ERR_INVALID_EVIDENCE_URL],
    "badLabel": ["https://-bad-.com/p", ERR_INVALID_EVIDENCE_URL],
    "emptyHost": ["https:///p", ERR_INVALID_EVIDENCE_URL]
};

@test:Config {dataProvider: rejectedUrls}
function evidenceUrlRejects(string raw, string code) {
    test:assertEquals(codeOf(parseEvidenceUrl(raw)), code);
}

@test:Config
function evidenceUrlLengthCap() {
    string path = "";
    foreach int i in 0 ..< EVIDENCE_URL_MAX_LENGTH {
        path += "a";
    }
    test:assertEquals(codeOf(parseEvidenceUrl("https://example.com/" + path)), ERR_EVIDENCE_URL_TOO_LONG);
    string ok = "https://example.com/" + path.substring(0, EVIDENCE_URL_MAX_LENGTH - 20);
    test:assertEquals(codeOf(parseEvidenceUrl(ok)), "OK");
}

@test:Config
function evidenceProviderAndUrnAreDetected() returns error? {
    EvidenceUrl feed = check parseEvidenceUrl("https://www.linkedin.com/feed/update/urn:li:activity:7123456789/");
    test:assertEquals(feed.provider, EVIDENCE_PROVIDER_LINKEDIN);
    test:assertEquals(feed.host, "www.linkedin.com");
    test:assertEquals(feed.resourceUrn, "urn:li:activity:7123456789");

    EvidenceUrl encoded = check parseEvidenceUrl("https://www.linkedin.com/feed/update/urn%3Ali%3Ashare%3A42");
    test:assertEquals(encoded.resourceUrn, "urn:li:share:42");

    EvidenceUrl post = check parseEvidenceUrl("https://www.linkedin.com/posts/avery_wso2-activity-7123456789-AbCd");
    test:assertEquals(post.resourceUrn, "urn:li:activity:7123456789");

    EvidenceUrl medium = check parseEvidenceUrl("https://wso2.medium.com/some-post");
    test:assertEquals(medium.provider, EVIDENCE_PROVIDER_MEDIUM);
    test:assertEquals(medium.resourceUrn, ());

    EvidenceUrl blog = check parseEvidenceUrl("https://blog.example.org/x");
    test:assertEquals(blog.provider, EVIDENCE_PROVIDER_OTHER);
}

@test:Config
function httpsUrlCheck() {
    test:assertTrue(isHttpsUrl("https://wso2.com/x.png"));
    test:assertFalse(isHttpsUrl("http://wso2.com/x.png"));
    test:assertFalse(isHttpsUrl("https://"));
    test:assertFalse(isHttpsUrl("https://a b"));
}

// Regression (deep review RC-02): the `/posts/...-activity-N` branch built a PostUrn without
// `parsePostUrn`, so a 300-digit id broke the URN invariant (255 characters, 100-character id).
@test:Config
function evidencePostsUrnKeepsTheUrnInvariant() returns error? {
    string digits = "";
    foreach int i in 0 ..< 300 {
        digits += "7";
    }
    EvidenceUrl long = check parseEvidenceUrl(string `https://www.linkedin.com/posts/avery_x-activity-${digits}-AbCd`);
    test:assertEquals(long.resourceUrn, (), "an id longer than a URN allows is not a resource URN");
    EvidenceUrl short = check parseEvidenceUrl("https://lnkd.in/posts/x-activity-42-z");
    test:assertEquals(short.provider, EVIDENCE_PROVIDER_LINKEDIN);
    test:assertEquals(short.resourceUrn, "urn:li:activity:42");
    EvidenceUrl other = check parseEvidenceUrl("https://www.linkedin.com/feed/update/urn:li:person:abc");
    test:assertEquals(other.resourceUrn, (), "a person URN is not a post");
}

@test:Config
function evidenceUrlPortAndHostEdges() returns error? {
    EvidenceUrl port = check parseEvidenceUrl("https://Example.COM.:8443/a/");
    test:assertEquals(port.normalized, "https://example.com:8443/a");
    EvidenceUrl defaultPort = check parseEvidenceUrl("https://example.com:443?b=2&a=1&utm_source=x");
    test:assertEquals(defaultPort.normalized, "https://example.com?a=1&b=2");
    foreach string bad in ["https://example.com:0/", "https://example.com:65536/", "https://example.com:/",
            "https://exa_mple.com/", "https://-a.com/", "https://0x7f000001/", "https://a..com/"] {
        test:assertTrue(parseEvidenceUrl(bad) is DomainError, bad);
    }
}
