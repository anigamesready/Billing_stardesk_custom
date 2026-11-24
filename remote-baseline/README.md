# Ani Games Ready Remote — Android DB Preview v0.2.0

This isolated branch previews the Remote Play client interface and basic local controls. It is NOT a production-connected client.

## Included
- User ID entry; a sample expired rental can still enter the dashboard.
- Coin wallet example, top-up presets Rp5k/Rp10k/Rp15k/Rp20k and manual rupiah amount.
- Conversion at Rp8,000 = 60 coins, and new-lot expiry preview using the agreed total-balance tiers.
- Ani Games Ready static QRIS, zoom, copy nominal and WhatsApp handoff to 082298316902.
- WhatsApp message explicitly says PREVIEW / DO NOT PROCESS; no order is created and no wallet is credited.
- Approved rates and sample PCs for GTX 1050, GTX 1660, RTX 3060, RTX 5060.
- Navigation, refresh sample list, and logout.

## Not active in this preview
- All displayed account balance, expiry state, PC state and history are demonstration data.
- No Supabase endpoint, API key or second database is included.
- No Android DB login, top-up order, payment approval, coin mutation or live PC list.
- PC selection only displays a notice; it does not start StarDesk.
- QRIS is static; payer must enter amount manually.

## Build
Branch: `stardesk-androiddb-preview-v2`
Application ID: `com.anigamesready.stardeskclient`
Version: `0.2.0-preview`, versionCode 2
Artifact name: `Ani-Games-Ready-Remote-AndroidDB-Preview-v0.2.0`

See `docs/ANDROID-DB-INTEGRATION-AUDIT.md` and `docs/ANDROID-DB-COIN-MODULE-DRAFT.md` before live integration.
