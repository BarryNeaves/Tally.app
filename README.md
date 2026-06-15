# Tally

> Tax made human.

A SwiftUI iOS app for tracking UK income, expenses, and tax liability. Self-assessment without the spreadsheet.

## Status

Early development. The shell and authentication flow are in place; the tracker views are scaffolded but not yet wired up.

| Area | State |
|---|---|
| Sign up / email verification / sign in | ✅ Implemented (local, no backend) |
| Face ID / Touch ID / Optic ID sign-in | ✅ Implemented |
| Brand design system (`tally.css`) | ✅ Applied to auth views and shell |
| Google Sign-In | ⚠️ Scaffolded — needs OAuth client ID |
| Facebook Login | ⚠️ Scaffolded — needs app config |
| Dashboard, entry list, tax summary | 🚧 Placeholder content |
| Real email service for verification codes | 🚧 Code is shown on-screen in demo mode |
| Password storage hardening (Keychain + PBKDF2/Argon2) | 🚧 Currently SHA256 + `UserDefaults` |

## Requirements

- Xcode 16+
- iOS 17+ deployment target
- Apple developer account (for biometrics + Google/Facebook on device)

## Getting Started

```bash
git clone https://github.com/BarryNeaves/Tally.app.git
cd Tally
open Tally.xcodeproj
```

Build & run the `Tally` scheme on simulator or device.

## Configuration

A few things must be filled in before social sign-in or biometrics work end-to-end.

### Face ID / Touch ID

Already configured. The Info.plist key `Privacy - Face ID Usage Description` is set in the target's build settings.

### Google Sign-In

1. Create an **OAuth 2.0 iOS client** at [console.cloud.google.com](https://console.cloud.google.com/apis/credentials) using bundle ID `com.logitude.Tally`.
2. Paste the client ID into `Tally/uk_tax_tracker.swift` (search for `YOUR_GOOGLE_CLIENT_ID`).
3. In Xcode → Tally target → **Info** → **URL Types**, add the **reversed client ID** as a URL Scheme (e.g. `com.googleusercontent.apps.123456789-abc`).

### Facebook Login

Not yet wired. To enable, add `FacebookAppID`, `FacebookClientToken`, and the `fb<APP_ID>` URL scheme to `Info.plist`.

## Project Layout

```
Tally/
├── Tally.xcodeproj/
├── Tally/
│   ├── TallyApp.swift          # App entry, SwiftData container
│   ├── uk_tax_tracker.swift    # Auth flow, brand system, tracker views
│   ├── ContentView.swift       # (unused — kept from template)
│   ├── Item.swift              # SwiftData model
│   ├── Info.plist              # URL Types for Google Sign-In
│   ├── tally.css               # Brand design system (source of truth)
│   └── Assets.xcassets/        # App icon (wordmark variant)
├── TallyTests/
└── TallyUITests/
```

## Brand System

The brand is defined in [`Tally/tally.css`](Tally/tally.css). The SwiftUI side mirrors it directly:

- **Colour tokens** → `C` struct (`C.sage`, `C.paper`, `C.ink`, `C.amber`, …)
- **Type / spacing / radius / shadow tokens** → `T` struct (`T.textBase`, `T.space4`, `T.radiusLg`, `T.shadowBtn`, …)
- **Components** → `TallyLogo`, `TallyIcon`, `TallyWordmark`
- **Style helpers** → `TallyPrimaryButtonStyle`, `TallyGhostButtonStyle`, `.tallyInput(focused:)`

When updating the brand, change `tally.css` first, then mirror the values into the Swift tokens to keep them in sync.

## Authentication Flow

1. **First launch** → Sign Up (email, password ≥ 8 chars, confirm).
2. **Email verification** → 6-digit code. Since there's no email backend yet, the code is shown on-screen in an amber callout.
3. **Sign In** → email + password.
4. **After first successful sign-in** → Face ID / Touch ID / Optic ID button appears on the sign-in screen.

State is persisted to `UserDefaults` (`userEmail`, `userPasswordHash`, `isEmailVerified`, `hasSignedInOnce`). The reset/sign-out controls call `LoginManager.resetAccount()` / `signOut()` if you need to start over.

## License

TBD.
