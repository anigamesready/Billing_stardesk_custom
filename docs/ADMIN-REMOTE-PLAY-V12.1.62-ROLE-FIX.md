# Admin V12.1.62 — Remote Play visibility fix

Date: 25 November 2026

## Root cause

The V12.1.61 build pipeline already applied the Remote Play Admin module, but its visibility and action guard accepted only an exact `ctx.role === "owner"` value. The existing Admin role resolver used by Wake-on-LAN also supports the established aliases `owner`, `master`, `master_owner`, `owner_master`, `master_admin`, `admin_master`, `super_admin`, and `superadmin`. An account returning one of those aliases could therefore see the other Owner-only controls while the Remote Play tab remained hidden.

## Change

- The Remote Play Admin role check now delegates to the existing canonical `isWakeRelayOwner()` resolver.
- The existing rental activation-code, PC Host permission/enrollment, and Remote Play status UI are retained; no pairing/stream engine or billing settlement is rewritten.
- Coin management continues to use the same role helper through `isRemotePlayOwner()`.
- Admin package identity remains `com.anigames.billingadmin.v161online` so V12.1.62 is an in-place update of the isolated V12.1.61 candidate; versionCode increases to 89.

## Verification

CI checks require the canonical role helper, all expected role aliases, Remote Play tab and RPC wiring, JavaScript syntax, APK metadata, APK signature verification, and archive integrity. A successful build does not prove the live Android DB migration state or real StarDesk streaming. Keep this APK as SAFE-TEST until a real-device Owner login and click-through confirms that the tab is visible and its dashboard/activation RPC calls succeed.
