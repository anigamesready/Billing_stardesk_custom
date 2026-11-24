# Coin Wallet Module — Additive Draft (NOT APPLIED)

Target: local Ani Games Ready Android DB PostgreSQL, schema `remote_play`. This file is a design draft; no SQL migration has been applied to Redmi or production.

## Business constants (approved by owner)
- Exchange rate: Rp8,000 = 60 coins.
- Top-up: Rp5,000 => 37.5; Rp10,000 => 75; Rp15,000 => 112.5; Rp20,000 => 150. Custom amount uses the same linear rate.
- PC prices per hour: GTX 1050 Rp6,000/45 coins; GTX 1660 Rp6,000/45; RTX 3060 Rp7,000/52.5; RTX 5060 Rp8,000/60.
- Coins/hour precision is numeric, never float; charge proportional to actual elapsed seconds.
- Expiry is computed for the NEW lot using total valid wallet balance after credit: <300=3d; 300–<600=7d; 600–<900=10d; 900–<1200=14d; 1200–<1500=17d; 1500–<1800=21d; 1800–<2100=24d; 2100–<2400=28d; >=2400=30d. Existing lot expiry never changes.
- Spend earliest-expiring lot first; expired residue is retained in history but cannot be spent.

## Proposed tables
1. `remote_play.coin_wallets`: one row per existing `public.rental_accounts.id`, wallet balance as `numeric(18,4)`, created/updated timestamps; no copy of rental identity.
2. `remote_play.coin_lots`: one row per approved top-up or future credit; wallet/account FK, original and remaining numeric coin quantities, `expires_at`, source order, created timestamp. Partial indexes for spendable lots.
3. `remote_play.coin_ledger`: append-only debit/credit/expiry/refund/adjustment history; before/after balances, amount, reference and idempotency key unique. Never update old ledger events.
4. `remote_play.topup_orders`: amount in whole rupiah, coin quantity numeric snapshot, expiry-days snapshot, payment method QRIS static, pending/approved/rejected, WhatsApp confirmation metadata, Admin approver + timestamps, idempotency/approval key unique. No credential or bank secret.
5. `remote_play.pc_coin_rates`: device_id FK to existing public.devices, normalized GPU class, hourly rupiah, hourly coin numeric, enabled, updated by owner/admin; snapshots of the selected rate stored against each session.
6. `remote_play.coin_session_billing`: one row per existing `remote_play.sessions.id`, billing mode, start/stop time, GPU and price snapshot, accumulated charged seconds/coins, settled flag and idempotency marker. Existing host command/pairing session remains the remote control-plane record.

## APIs to add to local Node allowlist
Client-authenticated:
- `remote_coin_wallet` / dashboard: valid balance, expiring lots, profile.
- `remote_coin_topup_create`: create pending request, snapshot selected amount/coins/expiry-days.
- `remote_coin_session_start`: reserve/check balance and bind to host session/rate.
- `remote_coin_session_heartbeat`: server-authoritative reconciliation; fail-closed on invalid session.
- `remote_coin_session_end`: idempotent settlement and stop command.
Admin-authenticated:
- `admin_remote_coin_topups`: list pending topups scoped to owner organization.
- `admin_remote_coin_approve_topup`: atomically approve one pending order and credit one lot/ledger.
- `admin_remote_coin_reject_topup`: reject with reason, no credit.
- `admin_remote_coin_rates_get/set`: rates per device/class and expiry policy visibility.

## Payment handoff
QRIS is static, so the client shows the QR and the exact transfer amount. Confirm opens WhatsApp `wa.me/6282298316902` with order ID, User ID, nominal and coin quantity and asks for transfer proof. This message must not itself approve or credit. Admin checks proof in WhatsApp and taps Approve in Admin APK; only the server approval function credits wallet once. The real top-up order must exist in Android DB before WhatsApp opens. The current APK is preview-only and deliberately labels its WhatsApp message as a test.

## Transaction and concurrency rules
- Lock wallet row `FOR UPDATE` before any lot mutation.
- Lot debit order: `expires_at ASC, created_at ASC, id ASC`.
- Lock the PC device and rate snapshot during remote session allocation.
- Unique idempotency keys on top-up approval, session start, heartbeat/settlement event.
- Coin calculations use `numeric`; e.g. coins/hour / 3600 * elapsed_seconds. No JS float or integer rounding for authoritative charge.
- Ledger is authoritative; wallet balance is a transactionally maintained cached aggregate, and periodic integrity query must reconcile it to credit/debit ledger sums.
- Never allow negative lots/wallet. A race for the same account or PC must serialize or fail.
- The server watchdog must handle missing heartbeats and insufficient balance; it must enqueue existing host `stop_stream` command and settle exactly once.
- Do not call existing `private.remote_play_settle_session` unchanged for a coin-wallet session: the existing function deducts `rental_accounts.remaining_seconds`. Add a new coin-safe settlement path or an explicit mutually exclusive billing mode.

## QRIS/admin UX
- Keep user top-up and admin review endpoints in the same local Android DB service.
- Admin APK addition is a new "Top-up Remote" addon menu; pending order loads full User ID + amount + coins from the DB so the admin never retypes it.
- Proof is initially sent via WhatsApp. Admin views WhatsApp proof then approves the pending database order; optional in-app proof upload can be added separately.
- Existing Admin authentication and role/org scope remain authoritative; reseller cannot approve top-ups or change owner rates.
