# Ani Games Ready Remote — UI Preview V1

Mobile-first interface preview with the approved purple/blue gaming theme.

- User ID entry screen
- Rental balance and expiry summary
- READY / ACTIVE / OFFLINE PC list
- Expired and zero-balance lock states
- Logout and refresh controls

## Preview
Open `index.html` in a browser. Use any ID for an active demo, `expired-demo` to view the expired lock, or `saldo-habis` to view the zero-balance lock.

## Important
This is a UI-only preview with sample data. It is not connected to Supabase and does not start StarDesk sessions. Connect remains deliberately disabled until the backend rental gate, each PC's StarDesk device ID, and the StarDesk account authorization flow are verified.

The supplied StarDesk 1.6.1 APK declares an exported `stardesk://external` deep-link activity. DEX strings include `stardesk://external/device/control?id=%s&source=%s&from=%s&expire=%d`. Ani Games Ready's main database already has rental_accounts, devices and rental_sessions. No StarDesk ID mapping was found in current device metadata.

Production rule: validate rental status, expiry, remaining seconds and selected PC server-side on every connect attempt. Never rely on client-side UI state for authorization.