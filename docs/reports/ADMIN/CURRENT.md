# Admin — Current Report

Last updated: 2026-11-27  
Status: Requirements and baseline notes; no Admin APK/source was modified in this task.

## Current selected audit baseline

- User-selected Admin comparison artifact: AniGames-Admin-Online-V12.1.58-SAFE-TEST.apk on main.
- The SAFE-TEST artifact is an audit baseline, not an approved production release.
- The repository skill's 2026-11-24 static audit recorded debuggable=true, remaining DB1/DB2 markup and JavaScript in the packaged assets, stage gateway/relay endpoints requiring verification, and no completed real-device/production API regression run.
- Main branch was observed at 950c2fc9858bbcec1a2f9696f72634dd000b45e5 before this reporting branch. Feature branch heads must be rechecked before any Admin source task.

## Partner features expected in Admin

Admin should be the only authority for:
- Creating, activating, suspending, and disabling Partner accounts.
- Issuing and rotating unique Partner codes.
- Setting Partner username and issuing/resetting credentials without revealing stored passwords.
- Configuring the four commission tiers and the count of transactions in each tier.
- Setting a schedule effective date/version and deciding whether a changed rule applies only to newly attributed members.
- Reviewing Partner member acquisition and anonymized operational metrics.
- Reviewing commission ledger entries and exceptions.
- Approving, rejecting, or marking Partner withdrawal requests as paid, with reason and audit trail.
- Viewing immutable change history for codes, rates, statuses, and payouts.

Partner controls must not be implemented by exposing Admin credentials or unrestricted DB access to the Partner role.

## Important implementation cautions

- Do not patch or repack the SAFE-TEST APK as though it were editable source.
- Locate and verify the matching editable Admin source inside this repository before source-level modifications. Compare the current branch and recent commits first.
- Keep the Android DB-only architecture; remove obsolete DB1/DB2 concepts rather than merely hiding them.
- Preserve existing stable Admin functions and use an isolated feature branch for substantial changes.
- A UI toggle or hidden menu is not sufficient proof of a backend permission boundary.

## Work log

### 2026-11-27 — Partner design intake
- Added Admin requirements to the Partner design report.
- No Admin source, APK, API, or live settings were changed.

Keywords: Admin APK, dashboard, partner management, commission configuration, payout approval, partner code, permissions, audit log, SAFE-TEST.
