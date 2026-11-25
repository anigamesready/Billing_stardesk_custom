# Ani Games Ready Remote — Android DB Auto Endpoint Preview v0.5.0

This Android Remote preview uses the Android DB API through the project's fixed Cloudflare HTTPS gateway. The endpoint is built into the native app; the renter does not need to enter or see a server URL.

## Included
- Automatic HTTPS gateway selection and native health probe. Login is enabled only when the gateway, relay agent, local API and Android DB all report healthy.
- Rental User ID activation and refresh-token login.
- Access and refresh tokens encrypted with Android Keystore AES-GCM.
- Live Android DB wallet balance, coin lots, transaction history and per-PC GPU rates.
- QRIS top-up order creation with idempotency and WhatsApp Owner confirmation.
- Coin amount labels and calculations use the approved x100 display unit: Rp8,000 = 6,000 coins.
- Account status and expiry display.
- PC availability and GPU rate states from Android DB.

## Deliberately not enabled yet
- PC Connect and StarDesk launch remain locked. The repository currently has no verified StarDesk host-agent stream callback source and no proven mobile stream-connected/disconnected callback contract. A start-command acknowledgement alone is not proof that the user is actually streaming.
- Coin session start/stop settlement is not connected to a proven streaming event. Do not reuse legacy Remote Play settlement because it deducts rental seconds.
- This is a Preview build; it has not passed a real phone-to-PC streaming and coin-settlement acceptance test.
- The fixed public endpoint still requires a live relay agent connection to the Android DB host. A public URL cannot make a disconnected host online.

## Build
Branch: `feature/remote-auto-url-coin-ui-20261125`
Application ID: `com.anigamesready.stardeskclient`
Version: `0.5.0-androiddb-auto-endpoint-preview`, versionCode 5

CI builds a debug APK and checks package metadata, signature, native HTTPS health probe, JavaScript syntax, UI contracts and x100 coin labels. This is a SAFE-TEST/Preview artifact, not a production release.
