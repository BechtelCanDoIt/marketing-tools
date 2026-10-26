# Runbook: Employee Data-Deletion Request (interim, phase 1 pilot)

Status: Draft (2026-10-16). Valid while the checklist exception is open.
Owner: Amplify technical owner (Scott Bechtel). Backup: a second Amplify engineer with prod DB access.
Why it's manual: [ADR-016](../../architecture/decisions/ADR-016-erasure-deferred.md).

## When to use this

An employee (or Legal / Privacy on their behalf) asks WSO2 to delete or anonymize their Amplify data. Requests can arrive through the privacy channel, PO, IT support or directly. **Whoever receives it forwards it to the owner the same day.**

If the employee only wants Amplify to stop posting for them, point them to **Me › Settings › My Connections › Remove Connection** first. That deletes the LinkedIn token immediately and needs no ticket.

## Timeline

| Step | Target |
| --- | --- |
| Acknowledge the request | 2 working days |
| Complete the change | 15 working days, and always inside the legal deadline Legal gives (typically one month) |
| Confirm to the requester | Same day as completion |

Legal / Privacy confirms these targets before go-live.

## Steps

1. **Log it.** Open a private ticket (security/privacy tracker) with the request date, requester, the employee's email, and who verified identity. Never put the employee's data in a public channel.
2. **Verify identity.** The request must come from the employee's own WSO2 account, or from Legal / Privacy. Find the Asgardeo `sub`:
   ```sql
   SELECT employee_id, email, display_name, first_seen_at, last_seen_at
   FROM identity.employee WHERE email = $email;
   ```
3. **Ask Legal / Privacy what to keep.** Default for the pilot: delete the LinkedIn link and token, remove name and email everywhere, keep ledger and audit rows keyed only by the pseudonymous `sub`. Record their answer in the ticket.
4. **Prepare the script** from the template below. A second engineer reviews it. Run it in **non-prod first** against a test user.
5. **Back up** the affected rows to an encrypted file in the restricted project store, kept only until the change is confirmed (max 7 days), then delete it. Note the deletion in the ticket.
6. **Run in prod** as `amplify_migrate` (the only user allowed to change these columns), inside one transaction, with the second engineer watching.
7. **Check the result** (queries at the end), then confirm to the requester and close the ticket.
8. **Tell the requester** to also remove the "WSO2 Amplify" app in LinkedIn › Settings › Data privacy › Permitted services. Amplify can't do that from our side.

## Script template

Run as `amplify_migrate`. Replace `:sub` with the employee's `employee_id`.

```sql
BEGIN;

-- 1. LinkedIn connection and tokens
DELETE FROM connection.provider_token WHERE owner_id = :sub;
UPDATE connection.member_connection
   SET removed_at = COALESCE(removed_at, now()), current_token_id = NULL, current_token_issued_on = NULL
 WHERE employee_id = :sub;
DELETE FROM connection.oauth_state WHERE employee_id = :sub;

-- 2. Short-lived request data
DELETE FROM messaging.idempotency_key WHERE employee_id = :sub;
UPDATE sharing.share_request SET commentary = NULL WHERE employee_id = :sub;

-- 3. Name and email
UPDATE identity.employee   SET email = NULL, display_name = 'Former participant' WHERE employee_id = :sub;
UPDATE recognition.standing SET email = NULL, display_name = 'Former participant' WHERE employee_id = :sub;

-- 4. Record the action (the audit log is append-only)
INSERT INTO audit.audit_log (at, actor_id, actor_roles, action, entity_type, entity_id, outcome, reason, correlation_id)
VALUES (now(), :operator_sub, ARRAY['amplify_migrate'], 'EMPLOYEE_DATA_DELETION_MANUAL', 'employee', :sub,
        'SUCCESS', :ticket_id, :ticket_id);

COMMIT;
```

Column names follow [phase1-data-model.md](../../architecture/solution/Phase%201/phase1-data-model.md). Check them against the live migrations before the first real use; this template is written before the schema exists.

**Not changed by default:** `scoring.points_ledger`, `sharing.engagement`, `external_sharing.external_share` and `audit.audit_log` rows. They keep only the pseudonymous `sub`. If Legal requires those removed too, stop and escalate: deleting ledger rows changes everyone's ranks and needs `POST /maintenance/rebuild-recognition` afterwards, so plan it with PO.

## Gotchas

- **If the person is still an employee and opens Amplify again**, `amplify-api` upserts their email and name on the next call. Remove them from the Amplify pilot group in Asgardeo, or agree with them that their next use re-creates a profile.
- **Recognition rebuild** (`POST /maintenance/rebuild-recognition`) reads names from `identity.employee`, so it keeps the anonymized values. Run it only after step 3.
- **Backups** still hold the old data until backup retention ends. Say so in the confirmation.

## Checks after the change

```sql
SELECT count(*) FROM connection.provider_token WHERE owner_id = :sub;               -- 0
SELECT email, display_name FROM identity.employee WHERE employee_id = :sub;         -- NULL, Former participant
SELECT count(*) FROM recognition.standing WHERE employee_id = :sub AND email IS NOT NULL;  -- 0
SELECT action, at FROM audit.audit_log WHERE entity_id = :sub ORDER BY at DESC LIMIT 1;    -- the manual entry
```
