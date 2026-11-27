# Database — Current Report

Last updated: 2026-11-27  
Status: Design/reporting snapshot; no schema or production data changed in this task.

## Confirmed architecture decisions

- The StarDesk custom project currently has one authoritative Android DB under the project skill.
- Do not revive DB1/DB2, primary/backup switching, dual-database synchronization, or a second database abstraction unless the user explicitly changes this decision.
- Inspect the real current schema, foreign keys, unique constraints, indexes, RLS/permissions where applicable, API routes, and all read/write call sites before proposing a migration.
- Prefer additive migrations with explicit rollback and regression tests. Do not invent existing table or column names.

## Partner requirements to account for in future DB design

These are requirements, not a statement that tables or columns already exist:
- A Partner login identity must be securely linked to one Partner profile.
- Admin issues a unique Partner code. It must be unique and cannot be chosen or changed by the Partner.
- When a Partner creates a new rental/member record while authenticated, the server derives the Partner identity/code from the authenticated session and attaches attribution automatically. Never trust a partner_id or partner_code submitted by the client.
- A member must have one stable attribution owner. Prevent a Partner from claiming an already existing member or reassigning another Partner's member.
- Commission progression is counted separately for each attributed member across up to 10 valid coin top-ups: transaction 1 at 20%; transactions 2–4 at 15%; transactions 5–7 at 10%; transactions 8–10 at 5%; transaction 11 onward at 0%.
- Record every commission as an auditable ledger entry tied to the exact top-up transaction, member, Partner, rule version, commission base, percentage, and status.
- Withdrawal requests and Admin decisions need their own audit trail. Available, pending, and paid balances must be derived from ledger events rather than manually editable totals.

## Integrity controls recommended before implementation

1. Use a unique stable member ID and a unique Partner code.
2. Derive Partner attribution server-side from the authenticated Partner account when creating a member.
3. Use an idempotency key / unique source transaction reference so a retried payment webhook cannot award the same commission twice.
4. Count only the defined eligible successful top-up events. Failed, pending, duplicate, test, refunded, or charged-back transactions must not create spendable commission.
5. Store a versioned commission rule snapshot with each member attribution or first eligible top-up so Admin changes do not silently rewrite historical earnings.
6. Make ledger entries append-only for normal application roles; corrections should be compensating entries with reason, actor, and timestamp.
7. Enforce authorization so a Partner can read only their own anonymized member/commission summaries and can request withdrawals only from their own available balance.
8. Keep payment, commission, and payout state transitions server-controlled and auditable.

## Open design decisions

- Commission base: recommended starting proposal is the eligible coin purchase amount actually charged after discounts, excluding payment admin fees and promotional/bonus coin value. This is not yet approved by the user.
- Channel eligibility: decide whether a member's top-up bought through a Reseller can also trigger Partner commission. Recommended safe default is to exclude reseller-channel top-ups from Partner commission unless the platform explicitly budgets both payouts.
- Refund/chargeback treatment: define a hold period and whether a settled transaction slot remains consumed after a later chargeback. Recommended anti-abuse behavior: reverse the commission with a compensating ledger entry; do not silently roll the member back to a higher commission tier after a late chargeback.
- Rule versioning: recommended default is to freeze the active commission-rule version for an attributed member, or at minimum from their first eligible top-up, so a mid-cycle Admin edit does not disadvantage an existing Partner.
- Confirm where Partner-created rental/member records belong in the approved Android DB model before writing a migration.

## Work log

### 2026-11-27 — Partner design intake
- Captured the Partner attribution and 10-transaction commission requirements.
- No schema migration, SQL, API, or live DB operation was performed.
- Next: inspect the current source/schema before turning these logical requirements into tables, policies, indexes, or RPC/API changes.

Keywords: Android DB, database, schema, migration, index, partner_id, partner_code, attribution, commission ledger, top-up, refund, idempotency, payout.
