# Security Checklist Exception Request: Employee Data Deletion (WSO2 Amplify pilot)

Status: **Draft, awaiting security team approval**
Requested by: Scott Bechtel (technical owner), 2026-10-16
Checklist: WSO2 Application Deployment Security Checklist › Data security › "Data deletion request" path
Decision record: [ADR-016](../../architecture/decisions/ADR-016-erasure-deferred.md) · Audit finding: C3 in [requirements-map.md](../../architecture/solution/Phase%201/requirements-map.md) · Interim process: [data-deletion-interim.md](../runbooks/data-deletion-interim.md)

## Request

We're asking for a time-boxed exception to the checklist item that requires an application-level path for employee data-deletion requests. WSO2 Amplify phase 1 will go live on **31 October 2026** for a pilot group without a built-in deletion or anonymization feature. Any request that arrives during the pilot is handled by the **manual interim process** linked above.

**Exception period:** from go-live (31 Oct 2026) to the end of the 90-day pilot, **29 January 2027**, or until the deletion path ships, whichever comes first.

## Why we're asking

Amplify keeps an append-only points ledger. Each row's `employee_id` can't be changed by the application roles (column-level grants), which is what makes points tamper-evident and auditable. Anonymizing that ledger without breaking its integrity, and without breaking the later handover of points to the WSO2 Coins programme, needs a proper design and a confirmed legal basis. We couldn't do that well and still hit the go-live date, so the feature is deferred rather than built in a hurry.

## What personal data the pilot holds

| Data | Where | Classification | Retention |
| --- | --- | --- | --- |
| Asgardeo `sub`, email, display name | `identity.employee`, `recognition.standing` | Internal / PII | Life of the programme |
| LinkedIn member URN, scopes, connection times | `connection.member_connection` | Internal / PII | Until Remove Connection |
| LinkedIn access token (`w_member_social`) | `connection.provider_token`, AES-256-GCM encrypted by the app | **Confidential** | Deleted on Remove Connection or reconnect; partition dropped at expiry + 5 days |
| Share commentary text | `sharing.share_request.commentary` | Internal | Cleared as soon as the share is published |
| Share and engagement records (URNs, times, kind) | `sharing.*` | Internal | Life of the programme |
| External share evidence URLs | `external_sharing.external_share` | Internal (public URLs) | Per plan D7 (open) |
| Points ledger rows | `scoring.points_ledger` | Internal | Life of the programme (needed for Coin settlement in phase 2) |
| Audit log (actor, action, changed fields) | `audit.audit_log` | Internal | 5 years |

No HR data, photos, location or team data are stored (ADR-009). Non-prod holds no real PII.

## Compensating controls

1. **Opt-in only.** Nothing about an employee is collected until they open Amplify, and no LinkedIn data until they choose to connect.
2. **Self-service removal of the sensitive part.** Remove Connection deletes the LinkedIn token row immediately and stops all posting. This covers the most sensitive data without any request.
3. **Data minimization.** Commentary is cleared on publish. No LinkedIn profile data beyond the member URN is kept. Evidence URLs are never fetched.
4. **Manual interim process** with named owners, timelines and an audited, two-person database change ([runbook](../runbooks/data-deletion-interim.md)).
5. **Small, known population.** The pilot is limited to an Asgardeo pilot group (15–25 Champions at launch, growing during the pilot) behind a preview flag.
6. **Encryption and access.** TLS everywhere, app-level encryption for tokens, per-component DB users, no admin user in the apps, prod access limited by Choreo roles.

## Residual risk

- A request during the pilot takes a manual DB change, so it's slower and depends on people following the runbook.
- Ledger rows keep the Asgardeo `sub` (a pseudonymous ID) after the name and email are removed, until the future design decides how to handle them. Legal needs to confirm this is acceptable under the legal basis recorded in the WSO2 Data Inventory.
- Backups keep deleted data until backup retention ends.

## Remediation plan

| Step | Target |
| --- | --- |
| Design ledger erasure (pseudonymize `employee_id` with a keyed mapping, or a reversal-and-reissue approach) and record the legal basis | During the pilot |
| Build `EmployeeErased` handling across contexts and a PO/Admin-triggered request path | Before phase 2 (Coin issue) |
| Close this exception | When the path is live, or 29 Jan 2027 review |

## Approvals

| Role | Name | Decision | Date |
| --- | --- | --- | --- |
| Security team | | ☐ Approved ☐ Rejected | |
| Legal / Privacy | | ☐ Approved ☐ Rejected | |
| Technical owner | Scott Bechtel | Requested | 2026-10-16 |
| Product owner (PO team) | | ☐ Acknowledged | |

If the security team rejects this, go-live needs the deletion path built first, and the 31 October date moves.
