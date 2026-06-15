# Tally

> Tax made human.

A SwiftUI iOS app — branded "UK Expense Tracker" — for tracking UK income, expenses, and tax liability. Self-assessment without the spreadsheet.

The root view is `UkExpenseTrackerView` (in `Tally/uk_tax_tracker.swift`). The auth flow, brand system, and tracker pages all live in that one file today.

## Status

Functional shell with brand pass complete. Tracker totals work; the tax-summary section is still placeholder maths.

| Area | State |
|---|---|
| Sign up / email verification / sign in | ✅ Local-only (no backend) |
| Face ID / Touch ID / Optic ID sign-in | ✅ Surfaced after first password sign-in |
| Brand design system (`tally.css`) | ✅ Wordmark + "Tax made human." strap on every page |
| Dashboard with profit / income / expense cards | ✅ |
| Expense + Income entry lists with brand rows | ✅ Recurrence/duration pills, paperclip count |
| Tax summary card (basic) | ⚠️ Personal allowance from tax code; no HMRC bands yet |
| Expense categories | ✅ General, Food, Transport, Salary, Tax, Domain names, Web hosting, SSL Certificates, GenAI |
| Recurrence (none / weekly / fortnightly / monthly / yearly) | ✅ |
| Duration (1 month / 1 year / 3 years) | ✅ For one-off purchases that cover a term |
| Currency per entry (GBP / USD) | ✅ Native symbol in row + live GBP equivalent |
| Mixed-currency totals normalised to GBP | ✅ Uses `usdRate` AppStorage |
| PDF attachments on entries | ✅ Multi-pick via `.fileImporter`, ShareLink, swipe-to-delete |
| Settings sheet (gear icon top-left) | ✅ |
| User profile — Name, NI number, Address, Date of birth | ✅ Stored locally |
| Light / Dark / System appearance toggle | ✅ Adaptive surfaces flip via `tally.css` dark tokens |
| Delete all data | ✅ Confirmation dialog — wipes profile, entries, attachments, account |
| Google Sign-In | ⚠️ Scaffolded — needs OAuth client ID + URL scheme |
| Facebook Login | ⚠️ Scaffolded — needs Facebook app config |
| Email service for verification codes | 🚧 Code is shown on-screen in an amber demo callout |
| Password storage hardening (Keychain + PBKDF2 / Argon2) | 🚧 Currently SHA256 + `UserDefaults` |
| Full HMRC tax bands & NI bands in summary | 🚧 |

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

Build & run the `Tally` scheme on simulator or device. On first launch you'll land on **Sign Up**.

## Configuration

A few things must be filled in before social sign-in or biometrics work end-to-end.

### Face ID / Touch ID

Already configured. The Info.plist key `Privacy - Face ID Usage Description` is set in the target's build settings.

### Google Sign-In

1. Create an **OAuth 2.0 iOS client** at [console.cloud.google.com](https://console.cloud.google.com/apis/credentials) using bundle ID `com.logitude.Tally`.
2. Paste the client ID into `Tally/uk_tax_tracker.swift` (search for `YOUR_GOOGLE_CLIENT_ID`).
3. In Xcode → Tally target → **Info** → **URL Types**, add the **reversed client ID** as a URL Scheme (e.g. `com.googleusercontent.apps.123456789-abc`).
4. Add `.onOpenURL { GIDSignIn.sharedInstance.handle($0) }` to `TallyApp` so the redirect is captured.

### Facebook Login

Not yet wired. To enable, add `FacebookAppID`, `FacebookClientToken`, and an `fb<APP_ID>` URL scheme to `Info.plist`.

## Project Layout

```
Tally/
├── Tally.xcodeproj/
├── Tally/
│   ├── TallyApp.swift          # App entry, launches UkExpenseTrackerView
│   ├── uk_tax_tracker.swift    # Auth flow + brand system + tracker views + settings
│   ├── ContentView.swift       # (unused — Xcode template leftover)
│   ├── Item.swift              # SwiftData model (unused at present)
│   ├── Info.plist              # URL Types for Google Sign-In
│   ├── tally.css               # Brand design system (source of truth)
│   └── Assets.xcassets/        # App icon (wordmark variant)
├── TallyTests/
└── TallyUITests/
```

## Brand System

The brand is defined in [`Tally/tally.css`](Tally/tally.css). The SwiftUI side mirrors it directly:

- **Colour tokens** → `C` struct (`C.sage`, `C.paper`, `C.ink`, `C.amber`, …)
- **Adaptive surfaces** — `paper`, `white`, `ink`, `mid`, `rule` resolve through `Color.dynamic(light:dark:)` so dark mode actually flips
- **Type / spacing / radius / shadow tokens** → `T` struct (`T.textBase`, `T.space4`, `T.radiusLg`, `T.shadowBtn`, …)
- **Brand components** → `TallyLogo`, `TallyIcon`, `TallyWordmark`, `TallyPageHeader`, `SummaryCard`, `EntryRow`, `TallyPill`
- **Style helpers** → `TallyPrimaryButtonStyle`, `TallyGhostButtonStyle`, `.tallyInput(focused:)`

Every screen (auth + tracker + settings) opens with the wordmark and "Tax made human." strap via `TallyPageHeader`.

When updating the brand, change `tally.css` first, then mirror the values into the Swift tokens to keep them in sync.

## Authentication Flow

1. **First launch** → Sign Up (email, password ≥ 8 chars, confirm).
2. **Email verification** → 6-digit code. Since there's no email backend yet, the code is shown on-screen in an amber callout.
3. **Sign In** → email + password.
4. **After first successful sign-in** → Face ID / Touch ID / Optic ID button appears on the sign-in screen.

State is persisted to `UserDefaults` (`userEmail`, `userPasswordHash`, `isEmailVerified`, `hasSignedInOnce`). `LoginManager.resetAccount()` wipes everything and returns to step 1.

## Data Model

```swift
struct Entry {
    var id: UUID
    var date: Date
    var description: String
    var amount: Double                  // in the entry's own currency
    var type: EntryType                 // income / expense / tax
    var category: Category
    var recurrence: Recurrence?         // weekly, monthly, yearly, …
    var duration: Duration?             // 1 month / 1 year / 3 years
    var attachments: [PDFAttachment]?
    var currency: Currency?             // GBP (default) or USD
}
```

### Currency conversion

Each entry stores its own currency. Totals on the Dashboard and Tax Summary normalise everything to GBP using `Entry.amountInGBP(usdRate:)`. The `usdRate` AppStorage default is `1.25` and represents the **GBP/USD market quote** (USD per 1 GBP), so the conversion is `usdAmount / usdRate`.

In the entry form, picking USD reveals an `≈ in GBP` row showing the live conversion. In each entry row, USD amounts show the native `$` then the GBP equivalent below in the USD-amber accent.

### Attachments

PDFs picked through `.fileImporter` are copied into `~/Documents/attachments/{uuid}.pdf` inside the app sandbox by `AttachmentStore`. Each `PDFAttachment` records the original `displayName` and the sandboxed `filename`. ShareLink opens them via the system share sheet. Swiping a row deletes the entity and the underlying file.

## Settings

Tap the gear icon top-left of the tracker shell. The sheet exposes:

- **Your details** — Name, NI number (auto-caps), Address (multi-line), optional Date of birth (stored as `UserProfile` JSON in `userProfileData`)
- **Appearance** — segmented picker for System / Light / Dark, applied via `preferredColorScheme` at the root
- **Danger zone** — Delete all data (confirmation dialog) clears attachments, entries, profile, account, then returns to Sign Up

## AppStorage Keys

| Key | Type | Purpose |
|---|---|---|
| `entriesData` | `Data` | JSON-encoded `[Entry]` |
| `taxYear` | `Int` | Active UK tax year |
| `taxCode` | `String` | e.g. `1257L` — drives personal allowance |
| `usdRate` | `Double` | GBP/USD quote for conversions |
| `userProfileData` | `Data` | JSON-encoded `UserProfile` |
| `appearanceMode` | `String` | `system` / `light` / `dark` |
| `userEmail` | `String` | Local account email |
| `userPasswordHash` | `String` | SHA256(password + email) |
| `isEmailVerified` | `Bool` | Gates Sign In after Sign Up |
| `hasSignedInOnce` | `Bool` | Gates Face ID button visibility |

## License

TBD.
