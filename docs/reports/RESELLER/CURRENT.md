# Reseller — Current Report

Last updated: 2026-11-27  
Status: Requirements snapshot; current Reseller source and schema have not been audited in this task.

## Known product requirements from project discussions

- Reseller is a separate commercial role from Partner.
- Reseller access should be limited to its own operational functions; it must not receive unrestricted database access.
- Previously discussed functions include reseller login, remembered account/session behavior, managing members brought by the reseller, changing available themes, coin/rental sales operations, and viewing its own activity.
- The user has referenced a reseller app baseline around v1.0.5 in prior discussions. That name is a historical reference only; it must not be assumed to be the newest editable source or a valid build baseline.
- Before any Reseller code or APK work, inspect the newest source/artifact in the authoritative StarDesk custom repository and compare branch history. Do not take an APK from another repository as a release artifact.

## Separation from Partner

| Area | Partner | Reseller |
|---|---|---|
| Main purpose | Acquire new rental members | Sell coin / operate reseller sales |
| Identity | Admin-issued Partner code | Reseller account / reseller identity |
| Member attribution | Server attaches Partner on Partner-created member | Reseller sales/member relationship follows Reseller rules |
| Earnings | Commission per eligible member top-up, capped at 10 benefit transactions | Margin from reseller's coin stock/sales as configured |
| Payout | Commission withdrawal approved by Admin | Reseller settlement/margin rules handled separately |
| Admin permissions | Partner account and commission controls | Reseller account, stock, price/margin controls |

## Financial conflict requiring a policy decision

A member can be attributed to a Partner but later purchase coin through a Reseller. If both Partner commission and Reseller margin are paid on the same top-up, platform contribution margin is reduced twice. Recommended safe default: reseller-channel top-ups earn the Reseller margin only and do not also generate Partner commission, unless the owner explicitly approves stacking and validates the economics.

## Open work

- Identify and audit the current Reseller source, branch, version, login/session behavior, and DB/API access.
- Confirm how reseller stock, top-up delivery, refunds, and margin ledger work.
- Define whether a Reseller can create a new rental member and how that differs from Partner member creation.
- Confirm whether Partner and Reseller attribution may coexist on one member; if so, specify how channel-based payout rules apply.

## Work log

### 2026-11-27 — Partner design intake
- Recorded the boundary between Partner and Reseller earning models.
- No Reseller source, APK, database, or live transactions were changed.

Keywords: reseller APK, reseller account, coin stock, sales margin, reseller member, Partner overlap, payout, commission stacking.
