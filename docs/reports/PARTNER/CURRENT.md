# Partner — Current Report

Last updated: 2026-11-27  
Status: Business rules and responsive HTML UX prototype v0.3 prepared for user audit. Not production-coded or connected to a backend.

## Confirmed requirements from the owner

1. Partner logs in with an Admin-issued username and password.
2. Provide an option to remember the account/session so the Partner does not repeatedly type credentials.
3. Each Partner receives a unique code issued by Admin.
4. When a logged-in Partner creates/registers a new rental member, the system automatically attaches that Partner attribution. The Partner does not manually type or select the attribution code.
5. Commission is calculated per attributed member over at most 10 valid coin top-up transactions:
   - Transaction 1: 20% (one transaction).
   - Transactions 2–4: 15% (three transactions).
   - Transactions 5–7: 10% (three transactions).
   - Transactions 8–10: 5% (three transactions).
   - Transaction 11 onward: 0%.
6. Commission rules and percentages must be configurable by Admin without rebuilding the app.
7. Partner sees masked member identity and summarized activity, not unrestricted personal or payment data.
8. Withdrawals are requested by Partner and manually approved by Admin.
9. No commission from downlines or multi-level recruitment is part of this design.

These requirements supersede the earlier concept of a customer manually entering a referral code and the earlier one-time fixed referral fee.

## UX prototype v0.3

Local review artifact: Ani-Games-Ready-Partner-UX-Review.html (provided separately in the current task response; sample data only).

Pages included:
- Partner username/password login with Remember Account preference.
- Overview dashboard and Admin-issued Partner code.
- New member registration with a read-only auto-attributed Partner code.
- Masked member list and member-specific progress.
- Read-only commission schedule and 0–12 transaction progress simulator.
- Coin transaction/commission history with status filters.
- Withdrawal form, sample minimum, and manual Admin approval history.
- Profile/security explanation.

The HTML is a UX demo only. It does not authenticate a real Partner, create a real rental member, contact a database, generate real coin, calculate production commission, or send a payout request. The demo's form actions and data are local simulation.

## Exact commission progression

| Valid transaction sequence for one member | Commission | Count |
|---|---:|---:|
| 1 | 20% | 1 |
| 2–4 | 15% | 3 |
| 5–7 | 10% | 3 |
| 8–10 | 5% | 3 |
| 11+ | 0% | unlimited |

If all ten eligible top-ups are equal in value, commission totals 110% of one top-up amount, equivalent to 11% of the aggregate value of those ten top-ups. Actual blended commission varies with each top-up's value. A first top-up still has a 20% payout rate, so the platform must confirm the net contribution margin can support it—especially when a member buys only once.

## Recommended security and accounting design

- Never store a raw password in localStorage or plaintext. For a web portal, use secure server-managed sessions / refresh cookies with Secure, HttpOnly, and SameSite protections; for Android, use platform-secure token storage. The UX preference should restore a valid session, not merely remember a password.
- Derive Partner identity and code server-side from the authenticated session when creating a member. Do not accept arbitrary partner_id/partner_code submitted by the browser.
- Reject duplicate/existing member IDs and prevent Partner self-claim/reassignment. Partner attribution should be stable; Admin corrections must be audited.
- Count only eligible settled coin top-ups. Enforce a unique source transaction reference so duplicate payment notifications cannot award commission twice.
- Use an append-only commission ledger with compensating reversals for refunds/chargebacks; do not make balances editable by Partners.
- Version commission schedules and preserve the rule used for each earning. Recommended default: a schedule is locked for a member from attribution or first eligible top-up so later Admin edits do not silently change an active member's benefits.
- Partner can see masked identity and aggregate transaction/benefit progress only. Use server-side row-level authorization for own members, own ledger, and own withdrawal requests.

## Recommended defaults that are NOT YET APPROVED

- Commission base: eligible coin purchase value actually paid after discounts, excluding payment admin fees and promotional/bonus coin value.
- Reseller channel: recommended safe default is that top-ups sold through a Reseller generate the Reseller margin only, not an additional Partner commission on that same transaction. This avoids stacking two payouts without an approved margin model.
- Refund/chargeback: commission should be reversed through a ledger correction. Define a validation/hold period; a late chargeback should not silently restore a higher commission tier.
- Minimum withdrawal: Rp50,000 was only a previous prototype example, not an approved policy.
- Commission schedule changes: define effective date and whether changes apply to new Partner-member relationships only.

## Decisions still needed before production coding

1. Confirm commission base (coin value paid after discounts, excluding admin/payment fees and bonus coin).
2. Confirm whether Partner commission applies to top-ups made through Resellers or only direct platform/app top-ups.
3. Confirm refund/chargeback hold window and whether a late reversed transaction still consumes its tier slot.
4. Confirm when the commission-rule version is frozen for a member.
5. Confirm whether Partner-created rental members become active immediately or need Admin approval, and validate the minimum required member fields against the real DB schema.
6. Confirm minimum withdrawal, supported payout destinations, schedule, and who is allowed to mark a payout as paid.

## Work log

### 2026-11-27 — Requirements and prototype v0.3
- Replaced manual referral-code entry with Admin-issued Partner code and server-side auto-attribution on Partner member creation.
- Replaced prior one-time referral fee with the 10-transaction commission ladder.
- Added login/remember-account UX, member registration, masked member list, commission simulator, transaction history, withdrawal UX, and security guidance.
- Ran Node JavaScript syntax validation on the prototype inline script; passed. No browser/device, database, authentication, payment, or payout integration test was performed.
- No production source, DB schema, APK, Admin, Remote, or Reseller implementation was changed.

Keywords: Partner, partner login, remember session, partner code, member attribution, new rental member, coin top-up, commission 20 15 10 5, 10 transactions, withdrawal, anonymized member, ledger, refund, reseller channel.
