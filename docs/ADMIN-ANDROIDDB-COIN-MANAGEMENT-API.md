# Admin Android DB — Coin Management API integration

Status: additive backend API prepared; Admin UI integration is still blocked by the missing editable source matching the selected Admin V12.1.58 SAFE-TEST baseline.

## Sole data authority

All records use the one Android DB PostgreSQL database and the existing local Android DB HTTPS gateway. The Admin app must call the authenticated RPC adapter; it must not connect to PostgreSQL tables directly or introduce a second database, DB1/DB2 selector, Supabase client, or fallback route.

## Available Admin RPCs

All Admin functions below require the current Android DB Admin session token and are organization-scoped by `private.remote_play_require_admin`.

| RPC | Inputs | Purpose |
|---|---|---|
| `admin_remote_coin_overview` | `p_limit` | Lists top-up orders across statuses, PC GPU rates, StarDesk ID mappings, Remote Play permissions, and summary counts |
| `admin_remote_coin_wallet` | `p_rental_account_id`, `p_history_limit` | Reads one rental's wallet, active/expired lots, ledger, and top-up history |
| `admin_remote_coin_topups` | `p_limit` | Existing pending top-up queue |
| `admin_remote_coin_approve_topup` | `p_order_id` | Existing idempotent approval/credit action |
| `admin_remote_coin_reject_topup` | `p_order_id`, `p_reason` | Existing rejection action |
| `admin_remote_coin_set_device_rate` | `p_device_id`, `p_gpu_class` | Existing approved GPU rate update |
| `admin_remote_coin_link_stardesk_device` | `p_device_id`, `p_stardesk_device_id`, `p_enabled` | Existing explicit StarDesk device mapping |

## Coin amount display

The database migration 022 stores the agreed display coin quantity in x100 units to preserve fractional values as integers at normal UI scales. The overview and wallet APIs return `coin_unit_scale`. The UI must display `amount / coin_unit_scale` and must never round the stored numeric values for accounting. The rate configuration remains:

- GTX 1050: Rp6.000/hour, 45 coins/hour
- GTX 1660: Rp6.000/hour, 45 coins/hour
- RTX 3060: Rp7.000/hour, 52.5 coins/hour
- RTX 5060: Rp8.000/hour, 60 coins/hour

For rate RPC responses where `hourly_coins` is 4,500 / 5,250 / 6,000, divide by the returned scale (100) for display only.

## Expected Admin screen behavior

1. Load `admin_remote_coin_overview` on entry and on explicit refresh.
2. Show pending top-ups first; display User ID/rental code, nominal, coin amount, expiry days, order time, and order status.
3. Approve or reject only pending orders. Confirm the action, call the corresponding RPC, then reload overview and wallet detail. Approval must never be simulated locally.
4. Let the operator select a rental account from the existing Admin rental list and load `admin_remote_coin_wallet`; display spendable balance, lot expiry, ledger, and order history.
5. Show each PC's GPU class, rupiah/hour, coins/hour, rate-enabled state, Remote Play permission, StarDesk Device ID and mapping status. Apply changes only through the existing Admin RPCs.
6. Show a visible error/retry state when the Android DB gateway is unavailable. Do not fall back to a second database or cached values for financial actions.

## Boundaries — deliberately not changed by this migration

- No existing public rental, device, billing-control, reseller or report tables are altered.
- No existing Remote Play session start/heartbeat/settlement function is replaced.
- No existing rental-time balance is debited or changed.
- Coin charging during an actual StarDesk stream remains disabled until a separate coin-session lifecycle is implemented and tested against real stream-connected/disconnected callbacks.
- This API document does not imply that the missing Admin UI has been integrated or that live Android DB has been migrated.

## Required source/UI gate

The selected Admin baseline is `AniGames-Admin-Online-V12.1.58-SAFE-TEST.apk`. An editable source matching that baseline has not been verified in this repository. The V12.1.60 candidate workflow was found to reconstruct a v12.1.4 project bundle and apply a long sequence of legacy patches, including dual-DB patches before attempting to hide/remove them. Do not use that workflow as the release source or alter/repackage the selected baseline APK as a substitute for source. Integrate this API into Admin only after the matching editable source is imported and audited, preserving all existing core feature paths.

## Migration and regression

Apply `023_admin_coin_management_read_api.sql` only after migrations 020–022 on an isolated staging database first. Run `018_admin_coin_management_read_api_smoke.sql` and the complete existing core, Remote Play, wallet, coin-scale, and WOL tests. Never apply it to the live Android DB until there is a verified backup and the API deployment is confirmed.
