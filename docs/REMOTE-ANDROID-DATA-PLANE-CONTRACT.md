# Remote Android Data Plane Contract

Status: implementation guardrail for the Android Remote preview. This document does not claim that a live StarDesk stream has been tested.

## Responsibilities

### Android custom app / phone
- Stores the Ani Games Ready client token in Android Keystore and keeps the User ID, account expiry, Coin wallet, lot history, top-up orders, selected PC, and session control state.
- Authenticates the rental account against the Ani Games Ready Android DB.
- Reads PC inventory, rates, owner permissions, availability and account balance/expiry.
- Requests an authorized session and signals start/stop/control events through the Android DB API.
- Hands video interaction to the installed StarDesk native client. The custom app is not a video player, media relay, or remote-desktop transport implementation.

### StarDesk Engine
- Owns the video/audio/input stream and the host-to-client media connection.
- The media path must remain StarDesk's native direct connection between the Windows host and StarDesk client. It must not be routed through the phone's local API, PostgreSQL, Cloudflare Gateway, or Redmi Relay Agent.
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

- Android Remote v0.5 already has account login/refresh, an Android DB dashboard, Coin wallet/top-up/history, GPU rates, account expiry display, and a locked Connect action.
- This branch adds a server-side account-expiry guard and makes an unverified PC state visibly yellow rather than green.
- The actual Windows StarDesk Host Agent, authenticated StarDesk session-connected/disconnected adapter, and end-to-end phone-to-PC stream acceptance test remain incomplete.
- Do not unlock Connect or deduct Coin until those real-device checks pass. The app must continue to hand the video path to StarDesk rather than embedding another streaming stack.
