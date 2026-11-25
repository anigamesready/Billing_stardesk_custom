# Remote Android Data Plane Contract

Status: implementation guardrail for the Android Remote preview. This document does not claim that a live StarDesk stream has been tested.

## Responsibilities

### Android custom app / phone
- Stores the Ani Games Ready client token in Android Keystore and keeps the User ID, account expiry, Coin wallet, lot history, top-up orders, selected PC, and session control state.
- Authenticates the rental account against the Ani Games Ready Android DB.
- Reads PC inventory, rates, owner permissions, availability and account balance/expiry.
- Requests an authorized session and signals start/stop/control events through the Android DB API.
- Once the authorization and host/session handoff are validated, hands video interaction to the installed StarDesk native client. In this preview, Connect remains locked; a successful StarDesk launch/stream handoff has not yet been proven. The custom app is not a video player, media relay, or remote-desktop transport implementation.

### StarDesk Engine
- Owns the video/audio/input stream and the host-to-client media connection.
- The media path must remain inside StarDesk's native host/client transport. StarDesk documents that it prefers peer-to-peer (P2P) and may fall back to its own encrypted relay when P2P is unavailable. That internal StarDesk fallback is still StarDesk's media path; it must never be routed through the Ani Games Ready phone API, PostgreSQL, Cloudflare Gateway, or Redmi Relay Agent.
- Ani Games Ready account credentials are not StarDesk credentials. Use StarDesk's existing authentication:
  - Remote Access with the same StarDesk account signed in on host and client; or
  - Remote Assist with the host Device ID and Verification Code shared by the host owner.
- A saved StarDesk device mapping alone does not prove authorization or an active stream.

## Data/control path versus video path

```text
Android Remote app  <---- HTTPS / RPC ---->  Ani Games Ready Android DB
       |                                         ^
       | launches / hands off to                 |
       v                                         | host control + status events
StarDesk native client  <==== StarDesk media ===> Windows StarDesk host
                                                 |
                                                 +-- Host Agent (control-plane only)
```

The Cloudflare Gateway and Redmi Relay Agent transport API/RPC/control traffic only. They must never forward video frames, audio packets, RTP/RTSP, WebRTC media, or any other StarDesk stream payload.

## Billing and truthful status rules

- A PC can be labelled `ONLINE • STAR DESK BELUM DIVERIFIKASI` when the legacy Billing device record is online, but that is not StarDesk readiness.
- Show StarDesk `READY` only after an authenticated Host Agent heartbeat confirms the expected StarDesk host installation, device mapping, and readiness signal.
- An intent dispatched to StarDesk, a process being present, an API command ACK, or a mapped Device ID is not proof that the video stream connected.
- Coin billing begins only on an authenticated StarDesk session-connected event. It ends on a corresponding stop/disconnect event or a server watchdog timeout. Settlement must be idempotent and based on server time and the rate snapshot.
- Never call the legacy rental-time settlement for a Coin session. Coin activity must not debit `rental_accounts.remaining_seconds`.
- Account status, explicit non-null future expiry, permission, positive unexpired Coin balance, PC readiness, and single-session constraints must be enforced server-side.

## Current implementation boundary

- Android Remote v0.6 already has account login/refresh, an Android DB dashboard, Coin wallet/top-up/history, GPU rates, account expiry display, and a locked Connect action.
- This branch adds a server-side account-expiry guard and makes an unverified PC state visibly yellow rather than green.
- The actual Windows StarDesk Host Agent, authenticated StarDesk session-connected/disconnected adapter, and end-to-end phone-to-PC stream acceptance test remain incomplete.
- Do not unlock Connect or deduct Coin until those real-device checks pass. The app must continue to hand the video path to StarDesk rather than embedding another streaming stack.
