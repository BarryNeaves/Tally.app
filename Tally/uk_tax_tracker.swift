//
//  uk_tax_tracker.swift
//

import SwiftUI
import Combine
import GoogleSignIn
import FacebookLogin
import LocalAuthentication
import CryptoKit
import UniformTypeIdentifiers
import Charts
import UserNotifications
import PDFKit

// MARK: - Models

struct Entry: Identifiable, Codable, Equatable {
    enum EntryType: String, Codable {
        case income, expense, tax
    }
    var id: UUID
    var date: Date
    var description: String
    var amount: Double
    var type: EntryType
    var category: Category
    var recurrence: Recurrence?
    var duration: Duration?
    var attachments: [PDFAttachment]?
    var currency: Currency?
    /// Set on entries that were auto-generated from a recurring template.
    /// References the template's `id`. User-created entries leave this nil.
    var parentEntryId: UUID?
    /// On a template: the date of the most recent auto-generated child.
    /// Used to skip forward instead of regenerating from `date` every pass.
    var lastGeneratedAt: Date?
    /// Free-form notes — receipts, context, anything that doesn't fit elsewhere.
    var notes: String?
    /// Explicit VAT rate on this entry. Nil / .unspecified means no detail —
    /// the Tax Summary falls back to a 20% estimate for those entries.
    var vatRate: VATRate?
    /// Who the entry was paid to (expense) or received from (income).
    /// Free-text, indexed by search.
    var vendor: String?
    /// Self-assessment deductibility. Defaults to true (allowable) when nil so
    /// existing entries keep counting toward the deductible total.
    var isAllowable: Bool?

    /// Defaults to true for legacy entries that don't have the flag set.
    var resolvedAllowable: Bool { isAllowable ?? true }

    /// Income category — only meaningful when type == .income. Defaults to
    /// `.freelance` for legacy entries via `resolvedIncomeType`.
    var incomeType: IncomeType?
    var resolvedIncomeType: IncomeType { incomeType ?? .freelance }

    /// VAT *included* in the gross `amount` if the user declared an explicit
    /// rate. Returns nil when no rate is set; the caller may then estimate.
    var explicitVATIncluded: Double? {
        guard let rate = vatRate?.rate else { return nil }
        return amount * rate / (1 + rate)
    }

    /// True when the user has declared a specific VAT status — even if it's
    /// zero-rated or exempt (so totals don't double-count via the estimate).
    var hasExplicitVAT: Bool {
        guard let vatRate, vatRate != .unspecified else { return false }
        return true
    }

    /// Resolved currency — older entries without the field default to GBP.
    var resolvedCurrency: Currency { currency ?? .gbp }

    /// `amount` converted to GBP. `usdRate` is the GBP/USD quote (USD per 1 GBP),
    /// so converting a USD amount to GBP is `amount / usdRate`.
    func amountInGBP(usdRate: Double) -> Double {
        switch resolvedCurrency {
        case .gbp: amount
        case .usd: usdRate > 0 ? amount / usdRate : amount
        }
    }

    /// Multiplier applied to `amount` to get the total cost over the contracted period.
    /// Only meaningful when BOTH a recurrence (≠ .none) and a duration are set —
    /// otherwise the amount is treated as the full one-off cost (multiplier = 1).
    var commitmentMultiplier: Double {
        guard let recurrence,
              recurrence != .none,
              recurrence.timesPerYear > 0,
              let duration else {
            return 1
        }
        return recurrence.timesPerYear * duration.inYears
    }

    var hasCommitment: Bool { commitmentMultiplier != 1 }

    /// Total cost over the duration (in the entry's own currency).
    var totalAmount: Double { amount * commitmentMultiplier }

    /// `totalAmount` normalised to GBP.
    func totalAmountInGBP(usdRate: Double) -> Double {
        switch resolvedCurrency {
        case .gbp: totalAmount
        case .usd: usdRate > 0 ? totalAmount / usdRate : totalAmount
        }
    }

    /// True when a duration is shorter than a single recurrence cycle — usually a mistake.
    var hasMismatchedDuration: Bool {
        guard let recurrence,
              recurrence != .none,
              let cycleYears = recurrence.yearsPerCycle,
              let duration else { return false }
        return duration.inYears < cycleYears
    }
}

struct Category: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var colorName: String
    
    // Workaround: SwiftUI Color is not Codable, so store color as a string name and map to Color
    var color: Color {
        switch colorName {
        case "primary":
            return C.primary
        case "secondary":
            return C.secondary
        case "green":
            return C.green
        case "red":
            return C.red
        case "background":
            return C.background
        case "cardBackground":
            return C.cardBackground
        case "textPrimary":
            return C.textPrimary
        case "textSecondary":
            return C.textSecondary
        case "orange":
            return Color.orange
        case "blue":
            return Color.blue
        // Additional colors from design tokens
        case "sage":
            return C.sage
        case "sageLight":
            return C.sageLight
        case "sagePale":
            return C.sagePale
        case "mint":
            return C.mint
        case "paper":
            return C.paper
        case "ink":
            return C.ink
        case "mid":
            return C.mid
        case "rule":
            return C.rule
        case "amber":
            return C.amber
        case "amberPale":
            return C.amberPale
        case "alert":
            return C.alert
        case "white":
            return C.white
        case "darkBase":
            return C.darkBase
        case "darkCard":
            return C.darkCard
            
        default:
            return C.primary
        }
    }
}

enum Recurrence: String, Codable, CaseIterable {
    case none, weekly, fortnightly, monthly, yearly, threeYearly

    var label: String {
        switch self {
        case .none:        "None"
        case .weekly:      "Weekly"
        case .fortnightly: "Fortnightly"
        case .monthly:     "Monthly"
        case .yearly:      "Yearly"
        case .threeYearly: "Every 3 years"
        }
    }

    /// How many billing cycles per year. `none` returns 0 (i.e. one-off).
    var timesPerYear: Double {
        switch self {
        case .none:        0
        case .weekly:      52
        case .fortnightly: 26
        case .monthly:     12
        case .yearly:      1
        case .threeYearly: 1.0 / 3.0
        }
    }

    /// Years per single cycle — useful for sanity-checking against duration.
    var yearsPerCycle: Double? {
        switch self {
        case .none:        nil
        case .weekly:      1.0 / 52.0
        case .fortnightly: 1.0 / 26.0
        case .monthly:     1.0 / 12.0
        case .yearly:      1.0
        case .threeYearly: 3.0
        }
    }

    /// Returns the date one recurrence cycle after `date`. Uses calendar
    /// arithmetic so month-end edge cases (e.g. 31 Jan + 1 month) collapse
    /// cleanly to the last day of the following month.
    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .none:        return nil
        case .weekly:      return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .fortnightly: return calendar.date(byAdding: .weekOfYear, value: 2, to: date)
        case .monthly:     return calendar.date(byAdding: .month, value: 1, to: date)
        case .yearly:      return calendar.date(byAdding: .year, value: 1, to: date)
        case .threeYearly: return calendar.date(byAdding: .year, value: 3, to: date)
        }
    }
}

// MARK: - Recurring auto-generation

/// Materialises missed recurrence cycles for any template entry whose next
/// cycle date has already passed. Returns the number of new entries added,
/// so the caller can show a toast.
///
/// Rules:
/// - Templates are entries with `parentEntryId == nil` and a non-`.none` recurrence.
/// - Children inherit description / amount / type / category / currency / recurrence
///   / duration from the template, get a fresh UUID, the cycle date, and a
///   `parentEntryId` pointing at the template.
/// - Children do NOT inherit the parent's PDF attachments (those refer to
///   real receipts and shouldn't be duplicated).
/// - If the template has a duration, generation stops at `template.date + duration`.
/// - A safety cap of 200 children per template per pass prevents runaway
///   generation if the system clock is wildly wrong.
@discardableResult
func autoGenerateRecurring(entries: inout [Entry], now: Date = Date()) -> Int {
    let calendar = Calendar.current
    var newChildren: [Entry] = []
    let cap = 200

    for index in entries.indices {
        guard entries[index].parentEntryId == nil,
              let recurrence = entries[index].recurrence,
              recurrence != .none else { continue }

        let template = entries[index]
        let endDate: Date = {
            guard let duration = template.duration else { return now }
            let days = Int(duration.inYears * 365.25)
            return calendar.date(byAdding: .day, value: days, to: template.date) ?? now
        }()
        let cutoff = min(now, endDate)

        var cursor = template.lastGeneratedAt ?? template.date
        var produced = 0
        var newLastGen: Date? = nil

        while produced < cap,
              let next = recurrence.nextDate(after: cursor),
              next <= cutoff {
            var child = template
            child.id = UUID()
            child.date = next
            child.parentEntryId = template.id
            child.lastGeneratedAt = nil
            child.attachments = nil
            newChildren.append(child)
            newLastGen = next
            cursor = next
            produced += 1
        }

        if let lastGen = newLastGen {
            entries[index].lastGeneratedAt = lastGen
        }
    }

    if !newChildren.isEmpty {
        entries.append(contentsOf: newChildren)
        entries.sort { $0.date < $1.date }
    }
    return newChildren.count
}

/// Category of income for tax purposes. Drives a refined Income Tax estimate
/// in the next iteration — PAYE is already taxed at source, dividends follow
/// their own bands, savings interest uses the personal savings allowance.
enum IncomeType: String, Codable, CaseIterable, Identifiable {
    case freelance  = "Freelance / self-employed"
    case paye       = "Salary (PAYE)"
    case dividend   = "Dividend"
    case rental     = "Rental"
    case interest   = "Savings interest"
    case other      = "Other"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// UK VAT rate applied to an entry. `unspecified` means the user hasn't
/// declared it and the Tax Summary should fall back to a 20% estimate.
/// `exempt` and `zeroRated` both contribute 0 VAT but are kept distinct
/// for reporting accuracy.
enum VATRate: String, Codable, CaseIterable, Identifiable {
    case unspecified = "Unspecified"
    case standard    = "Standard (20%)"
    case reduced     = "Reduced (5%)"
    case zeroRated   = "Zero-rated"
    case exempt      = "Exempt"

    var id: String { rawValue }
    var label: String { rawValue }

    /// VAT fraction included in a gross amount. Nil = no detail (caller falls back).
    var rate: Double? {
        switch self {
        case .unspecified: nil
        case .standard:    0.20
        case .reduced:     0.05
        case .zeroRated, .exempt: 0.0
        }
    }
}

/// Currency an entry is recorded in. Totals are always normalised to GBP.
enum Currency: String, Codable, CaseIterable, Identifiable {
    case gbp = "GBP"
    case usd = "USD"

    var id: String { rawValue }
    var symbol: String {
        switch self { case .gbp: "£"; case .usd: "$" }
    }
    var label: String {
        switch self { case .gbp: "GBP £"; case .usd: "USD $" }
    }
}

/// How long a one-off purchase covers (e.g. domain bought for 1 year).
/// Distinct from `Recurrence`, which describes how often a payment repeats.
enum Duration: String, Codable, CaseIterable, Identifiable {
    case oneMonth   = "1 month"
    case oneYear    = "1 year"
    case threeYears = "3 years"

    var id: String { rawValue }
    var label: String { rawValue }

    var inYears: Double {
        switch self {
        case .oneMonth:   1.0 / 12.0
        case .oneYear:    1.0
        case .threeYears: 3.0
        }
    }
}

// MARK: - User Profile

struct UserProfile: Codable, Equatable {
    var name: String = ""
    var niNumber: String = ""
    var address: String = ""
    var dateOfBirth: Date? = nil
}

// MARK: - Appearance

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

// MARK: - PDF Attachments

struct PDFAttachment: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    /// Filename within the app's attachments directory (uuid.pdf).
    var filename: String
    /// Original filename for display.
    var displayName: String
    var dateAdded: Date
}

/// Manages PDF files copied into the app's Documents/attachments folder.
final class AttachmentStore {
    static let shared = AttachmentStore()
    private init() {}

    private var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func url(for attachment: PDFAttachment) -> URL {
        directory.appendingPathComponent(attachment.filename)
    }

    /// Copy a user-picked PDF into our sandboxed attachments directory.
    func importPDF(from sourceURL: URL) -> PDFAttachment? {
        let id = UUID()
        let filename = "\(id.uuidString).pdf"
        let dest = directory.appendingPathComponent(filename)

        let needsAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return PDFAttachment(
                id: id,
                filename: filename,
                displayName: sourceURL.lastPathComponent,
                dateAdded: Date()
            )
        } catch {
            return nil
        }
    }

    func delete(_ attachment: PDFAttachment) {
        try? FileManager.default.removeItem(at: url(for: attachment))
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Auth Flow

enum AuthFlowStep {
    case signUp
    case verifyEmail
    case signIn
    case authenticated
}

// MARK: - Login Manager

class LoginManager: ObservableObject {
    @Published var step: AuthFlowStep = .signUp
    @Published var biometricError: String?
    @Published var formError: String?
    /// Demo only: surfaced on screen because there is no email service wired up yet.
    @Published var pendingVerificationCode: String?

    private let defaults = UserDefaults.standard
    private let emailKey = "userEmail"
    private let passwordHashKey = "userPasswordHash"
    private let emailVerifiedKey = "isEmailVerified"
    private let signedInOnceKey = "hasSignedInOnce"

    // Replace this with your actual Google Client ID string
    private static let googleClientID = "YOUR_GOOGLE_CLIENT_ID"

    var storedEmail: String {
        defaults.string(forKey: emailKey) ?? ""
    }

    private var storedPasswordHash: String {
        defaults.string(forKey: passwordHashKey) ?? ""
    }

    private var isEmailVerified: Bool {
        defaults.bool(forKey: emailVerifiedKey)
    }

    private var hasSignedInOnce: Bool {
        defaults.bool(forKey: signedInOnceKey)
    }

    /// Returns the biometry type supported by the device, or `.none` if unavailable.
    var availableBiometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        return context.biometryType
    }

    /// User-controllable toggle in Settings. Defaults to `true` (the
    /// previous always-on behaviour) on first read, so existing users
    /// don't lose Face ID after upgrading.
    var biometricEnabled: Bool {
        if defaults.object(forKey: "biometricEnabled") == nil { return true }
        return defaults.bool(forKey: "biometricEnabled")
    }

    /// Face ID/Touch ID is only offered when:
    ///  - the device supports + has biometrics enrolled
    ///  - the user has signed in at least once with a password
    ///  - the Settings toggle is on
    var canUseBiometrics: Bool {
        biometricEnabled && hasSignedInOnce && availableBiometryType != .none
    }

    init() {
        determineInitialStep()
    }

    private func determineInitialStep() {
        // If a local account exists but isn't verified yet, jump straight to verify.
        // Otherwise default to Sign In — even on a fresh device — and let the
        // user choose Sign Up from there. This matches how most apps onboard
        // and avoids stranding returning users (who reinstalled, restored, or
        // wiped data) on a screen with no path back to their account.
        if !storedEmail.isEmpty && !isEmailVerified {
            issueVerificationCode()
            step = .verifyEmail
        } else {
            step = .signIn
        }
    }

    // MARK: - Sign Up

    func signUp(email: String, password: String, confirmPassword: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEmail(trimmedEmail) else {
            formError = "Please enter a valid email address."
            return
        }
        guard password.count >= 8 else {
            formError = "Password must be at least 8 characters."
            return
        }
        guard password == confirmPassword else {
            formError = "Passwords do not match."
            return
        }

        defaults.set(trimmedEmail, forKey: emailKey)
        defaults.set(hash(password: password, email: trimmedEmail), forKey: passwordHashKey)
        defaults.set(false, forKey: emailVerifiedKey)
        defaults.set(false, forKey: signedInOnceKey)

        formError = nil
        issueVerificationCode()
        step = .verifyEmail
    }

    func goToSignIn() {
        formError = nil
        step = .signIn
    }

    func goToSignUp() {
        formError = nil
        step = .signUp
    }

    // MARK: - Email Verification

    func issueVerificationCode() {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        pendingVerificationCode = code
        // TODO: In production, dispatch this via your email backend (SendGrid, Postmark, etc.).
    }

    func verifyEmail(code: String) {
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected = pendingVerificationCode, entered == expected else {
            formError = "Incorrect verification code."
            Haptics.error()
            return
        }
        defaults.set(true, forKey: emailVerifiedKey)
        pendingVerificationCode = nil
        formError = nil
        step = .signIn
        Haptics.success()
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !storedEmail.isEmpty else {
            formError = "No account found. Please sign up first."
            return
        }
        guard trimmedEmail == storedEmail,
              hash(password: password, email: trimmedEmail) == storedPasswordHash else {
            formError = "Incorrect email or password."
            return
        }
        guard isEmailVerified else {
            formError = "Please verify your email before signing in."
            issueVerificationCode()
            step = .verifyEmail
            return
        }
        defaults.set(true, forKey: signedInOnceKey)
        formError = nil
        biometricError = nil
        step = .authenticated
        Haptics.success()
    }

    func signOut() {
        step = .signIn
        Haptics.impact()
    }

    /// Wipes the local account. Intended for testing while there is no backend.
    func resetAccount() {
        defaults.removeObject(forKey: emailKey)
        defaults.removeObject(forKey: passwordHashKey)
        defaults.removeObject(forKey: emailVerifiedKey)
        defaults.removeObject(forKey: signedInOnceKey)
        pendingVerificationCode = nil
        formError = nil
        biometricError = nil
        step = .signUp
    }

    // MARK: - Biometric Sign In

    func loginWithBiometrics() {
        guard canUseBiometrics else {
            biometricError = "Sign in with a password first to enable biometric sign-in."
            return
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            DispatchQueue.main.async {
                self.biometricError = error?.localizedDescription ?? "Biometric authentication is not available."
            }
            return
        }

        let reason = "Sign in to Tally"
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evalError in
            DispatchQueue.main.async {
                if success {
                    self.biometricError = nil
                    self.step = .authenticated
                    Haptics.success()
                } else {
                    self.biometricError = evalError?.localizedDescription ?? "Biometric authentication failed."
                    Haptics.error()
                }
            }
        }
    }

    // MARK: - Helpers

    private func hash(password: String, email: String) -> String {
        // SHA256(password + email) — adequate for a local demo. Replace with
        // PBKDF2/Argon2 + Keychain storage for production.
        let salted = password + "::" + email
        let digest = SHA256.hash(data: Data(salted.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }
    
    func loginWithGoogle() {
        // The presentingViewController is required for the sign-in flow.
        // Since we are in SwiftUI, walk the scene graph for the root VC.
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            print("RootViewController not found")
            return
        }

        GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController) { signInResult, error in
            if let error = error {
                print("Google Sign-In error: \(error.localizedDescription)")
                return
            }
            guard signInResult?.user != nil else {
                print("Google Sign-In user data not available")
                return
            }
            DispatchQueue.main.async {
                self.step = .authenticated
            }
        }
    }
    
    func loginWithFacebook() {
        // TODO: Integrate Facebook Login SDK here
        
        let loginManager = FacebookLogin.LoginManager()
        
        // Get root view controller for presenting
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            print("RootViewController not found")
            return
        }
        
        loginManager.logIn(permissions: ["public_profile", "email"], from: rootViewController) { result, error in
            if let error = error {
                print("Facebook Login error: \(error.localizedDescription)")
                return
            }
            
            guard let result = result, !result.isCancelled else {
                print("Facebook Login cancelled")
                return
            }
            
            // Successful login
            DispatchQueue.main.async {
                self.step = .authenticated
            }
        }
    }
}

// MARK: - Tax Year Helpers

let taxYears: [Int] = {
    // Generate a range of tax years from 2010 to 2030 for example
    Array(2010...2030)
}()

func currentTaxYear() -> Int {
    let now = Date()
    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month, .day], from: now)
    guard let year = components.year, let month = components.month, let day = components.day else { return 2026 }
    // UK tax year runs from April 6 to April 5 next year. Anything before
    // April 6 belongs to the previous tax year.
    if month > 4 || (month == 4 && day >= 6) {
        return year
    }
    return year - 1
}

/// `true` if `date` falls within the UK tax year starting 6 April `taxYear`.
func dateIsInTaxYear(_ date: Date, taxYear: Int) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
    guard let start = calendar.date(from: DateComponents(year: taxYear, month: 4, day: 6)),
          let end = calendar.date(from: DateComponents(year: taxYear + 1, month: 4, day: 6))
    else { return false }
    return date >= start && date < end
}

/// Compact tax-year label, e.g. `26/27` for year 2026.
func taxYearShortLabel(_ taxYear: Int) -> String {
    let a = String(taxYear).suffix(2)
    let b = String(taxYear + 1).suffix(2)
    return "\(a)/\(b)"
}

/// Returns the UK tax-year integer that a date falls within.
func calendarTaxYear(for date: Date) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
    let comps = calendar.dateComponents([.year, .month, .day], from: date)
    guard let y = comps.year, let m = comps.month, let d = comps.day else { return currentTaxYear() }
    return (m > 4 || (m == 4 && d >= 6)) ? y : y - 1
}

// MARK: - Color Constants
// Color tokens taken from the CSS design system

struct C {
    // Brand palette — sourced from tally.css :root tokens
    static let sage = Color(hex: "#4A7C59")           // Primary CTA, active states
    static let sageLight = Color(hex: "#6BA87A")      // Income, positive values
    static let sagePale = Color.dynamic(light: "#EEF5F0", dark: "#1F2A24") // Card fills
    static let mint = Color(hex: "#B8DFC4")           // Badges, soft borders
    // Adaptive surfaces — flip to the dark tokens from tally.css in dark mode
    static let paper = Color.dynamic(light: "#F7F6F1", dark: "#0F1117")  // App background
    static let ink   = Color.dynamic(light: "#1A1C18", dark: "#F0F2FF")  // Primary text
    static let mid   = Color.dynamic(light: "#4A4D46", dark: "#7B82A0")  // Secondary text
    static let rule  = Color.dynamic(light: "#DDE0D8", dark: "#2E3348")  // Dividers
    static let white = Color.dynamic(light: "#FFFFFF", dark: "#1C1F2A")  // Card surface
    static let amber = Color(hex: "#D4862A")          // Tax callouts, crossbar
    static let amberPale = Color(hex: "#FFF3E0")      // Amber card background
    static let alert = Color(hex: "#E05252")          // Errors, delete, overdue
    static let usd = Color(hex: "#F7A928")            // USD accent

    // Dark surfaces
    static let darkBase = Color(hex: "#0F1117")
    static let darkCard = Color(hex: "#1C1F2A")
    static let darkCard2 = Color(hex: "#252836")
    static let darkBorder = Color(hex: "#2E3348")
    static let darkInput = Color(hex: "#13161F")

    // Semantic aliases (kept for back-compat with existing views)
    static let primary = sage
    static let secondary = amber
    static let green = sageLight
    static let red = alert
    static let background = paper
    static let cardBackground = white
    static let textPrimary = ink
    static let textSecondary = mid
}

// MARK: - Color Helper Init from Hex

extension Color {
    /// Initialize Color from hex string like "#RRGGBB" or "RRGGBB"
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: // RRGGBB
            r = (int >> 16) & 0xFF
            g = (int >> 8) & 0xFF
            b = int & 0xFF
        default:
            r = 0; g = 0; b = 0
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }

    /// Adaptive color that resolves differently for light vs dark traits.
    static func dynamic(light: String, dark: String) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark)
                : UIColor(hex: light)
        })
    }
}

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            r = (int >> 16) & 0xFF
            g = (int >> 8) & 0xFF
            b = int & 0xFF
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: CGFloat(r) / 255,
                  green: CGFloat(g) / 255,
                  blue: CGFloat(b) / 255,
                  alpha: 1)
    }
}

// MARK: - Typography, Spacing, Radius, Shadow, Transition Tokens
// Taken from the CSS design system

struct T {
    // Type scale (matches tally.css --tally-text-*)
    static let textXs: CGFloat   = 11
    static let textSm: CGFloat   = 13
    static let textBase: CGFloat = 15
    static let textMd: CGFloat   = 17
    static let textLg: CGFloat   = 22
    static let textXl: CGFloat   = 28
    static let text2xl: CGFloat  = 38
    static let text3xl: CGFloat  = 52

    // Spacing scale (matches tally.css --tally-space-*)
    static let space1: CGFloat  = 4
    static let space2: CGFloat  = 8
    static let space3: CGFloat  = 12
    static let space4: CGFloat  = 16
    static let space5: CGFloat  = 20
    static let space6: CGFloat  = 24
    static let space8: CGFloat  = 32
    static let space10: CGFloat = 40
    static let space12: CGFloat = 48

    // Radius
    static let radiusSm: CGFloat   = 8
    static let radiusMd: CGFloat   = 12
    static let radiusLg: CGFloat   = 16
    static let radiusXl: CGFloat   = 24
    static let radiusPill: CGFloat = 999

    // Shadows
    static let shadowCard  = Shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 2)
    static let shadowModal = Shadow(color: Color.black.opacity(0.18), radius: 48, x: 0, y: 16)
    static let shadowBtn   = Shadow(color: Color(hex: "#4A7C59").opacity(0.35), radius: 20, x: 0, y: 4)

    // Back-compat aliases used by existing helpers
    static let fontDisplay: CGFloat    = textXl
    static let fontBody: CGFloat       = textBase
    static let fontEyebrow: CGFloat    = textXs
    static let fontDataLabel: CGFloat  = textXs
    static let fontHeroNumber: CGFloat = text2xl
    static let spacingXs: CGFloat = space1
    static let spacingSm: CGFloat = space2
    static let spacingMd: CGFloat = space4
    static let spacingLg: CGFloat = space6
    static let spacingXl: CGFloat = space8
    static let shadowSm = shadowCard
    static let shadowMd = shadowModal

    // Transition
    static let transitionFast = 0.18
    static let transitionNormal = 0.3
    static let transitionSlow  = 0.5

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
}

// MARK: - Font Extensions for Common Text Styles

extension Font {
    // Display — DM Serif Display analogue via system serif design
    static var display: Font {
        Font.system(size: T.textXl, weight: .regular, design: .serif)
    }
    static var displayLg: Font {
        Font.system(size: T.text2xl, weight: .regular, design: .serif)
    }
    static var displayItalic: Font {
        Font.system(size: T.textXl, weight: .regular, design: .serif).italic()
    }
    static var strapline: Font {
        Font.system(size: T.textXl, weight: .regular, design: .serif).italic()
    }
    static var bodyText: Font {
        Font.system(size: T.textBase, weight: .regular, design: .default)
    }
    static var eyebrow: Font {
        Font.system(size: T.textXs, weight: .bold, design: .default).smallCaps()
    }
    static var dataLabel: Font {
        Font.system(size: T.textXs, weight: .semibold, design: .default).smallCaps()
    }
    static var heroNumber: Font {
        Font.system(size: T.text2xl, weight: .heavy, design: .default)
    }
}

// MARK: - Brand Components

/// The Tally mark — four sage bars crossed by an amber diagonal (the "fifth" tally stroke).
struct TallyLogo: View {
    enum Size { case sm, md, lg }
    var size: Size = .md
    var barColor: Color = C.white
    var crossColor: Color = C.amber

    private var barWidth: CGFloat {
        switch size { case .sm: 3; case .md: 4; case .lg: 7 }
    }
    private var barHeight: CGFloat {
        switch size { case .sm: 20; case .md: 34; case .lg: 64 }
    }
    private var gap: CGFloat {
        switch size { case .sm: 4; case .md: 6; case .lg: 11 }
    }
    private var crossHeight: CGFloat {
        switch size { case .sm: 3; case .md: 4; case .lg: 7 }
    }
    private var barRadius: CGFloat {
        switch size { case .sm: 2; case .md: 3; case .lg: 4 }
    }

    var body: some View {
        ZStack {
            HStack(spacing: gap) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: barRadius)
                        .fill(barColor)
                        .frame(width: barWidth, height: barHeight)
                }
            }
            RoundedRectangle(cornerRadius: barRadius)
                .fill(crossColor)
                .frame(height: crossHeight)
                .padding(.horizontal, -gap)
                .rotationEffect(.degrees(-20))
        }
        .frame(height: barHeight)
        .fixedSize()
    }
}

/// Rounded sage tile containing the Tally mark, with a subtle highlight orb.
struct TallyIcon: View {
    enum Size: CGFloat { case s29 = 29, s40 = 40, s76 = 76, s120 = 120, s180 = 180 }
    var size: Size = .s40
    var variant: Variant = .sage

    enum Variant { case sage, dark, white }

    private var background: Color {
        switch variant { case .sage: C.sage; case .dark: C.ink; case .white: C.white }
    }
    private var orbColor: Color {
        switch variant {
        case .sage: C.sageLight
        case .dark: Color(hex: "#2A2D28")
        case .white: C.sagePale
        }
    }
    private var logoBarColor: Color {
        switch variant {
        case .sage: C.white
        case .dark: C.sageLight
        case .white: C.sage
        }
    }
    private var radius: CGFloat {
        switch size {
        case .s29: 7
        case .s40: 10
        case .s76: 18
        case .s120: 28
        case .s180: 40
        }
    }
    private var logoSize: TallyLogo.Size {
        switch size { case .s29, .s40: .sm; case .s76: .md; case .s120, .s180: .lg }
    }
    private var orbOpacity: Double {
        variant == .dark ? 0.8 : 0.28
    }

    var body: some View {
        ZStack {
            background
            GeometryReader { geo in
                Circle()
                    .fill(orbColor)
                    .opacity(orbOpacity)
                    .frame(width: geo.size.width * 0.65, height: geo.size.height * 0.65)
                    .offset(x: geo.size.width * 0.5, y: -geo.size.height * 0.25)
            }
            TallyLogo(size: logoSize, barColor: logoBarColor)
        }
        .frame(width: size.rawValue, height: size.rawValue)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: size.rawValue >= 120 ? Color.black.opacity(0.28) : .clear,
                radius: 30, x: 0, y: 24)
    }
}

/// Icon + "Tally" wordmark with a small sage dot.
struct TallyWordmark: View {
    enum Layout { case standard, hero }
    var layout: Layout = .standard
    var onDark: Bool = false

    private var fontSize: CGFloat { layout == .hero ? 64 : 32 }
    private var dotSize: CGFloat { layout == .hero ? 11 : 7 }
    private var iconSize: TallyIcon.Size { layout == .hero ? .s76 : .s40 }
    private var nameColor: Color { onDark ? C.white : C.ink }

    var body: some View {
        HStack(spacing: 14) {
            TallyIcon(size: iconSize)
            HStack(alignment: .top, spacing: 2) {
                Text("Tally")
                    .font(.system(size: fontSize, weight: .regular, design: .serif))
                    .foregroundColor(nameColor)
                    .tracking(-0.5)
                Circle()
                    .fill(C.sageLight)
                    .frame(width: dotSize, height: dotSize)
                    .padding(.top, fontSize * 0.15)
            }
        }
    }
}

/// Standard page header used on every screen — wordmark + "Tax made human." strap.
struct TallyPageHeader: View {
    var title: String? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: T.space3) {
            VStack(spacing: T.space2) {
                TallyWordmark()
                Text("Tax made human.")
                    .font(.strapline)
                    .foregroundColor(C.sage)
            }
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: T.space1) {
                    if let title {
                        Text(title)
                            .font(.displayLg)
                            .foregroundColor(C.ink)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.bodyText)
                            .foregroundColor(C.mid)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, T.space2)
            }
        }
        .padding(.horizontal, T.space6)
        .padding(.top, T.space5)
        .padding(.bottom, T.space4)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Brand Style Modifiers

/// Pill-shaped primary CTA — sage fill, white text, brand shadow.
struct TallyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: T.textBase, weight: .bold))
            .foregroundColor(C.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, T.space6)
            .background(C.sage)
            .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
            .shadow(color: T.shadowBtn.color, radius: T.shadowBtn.radius,
                    x: T.shadowBtn.x, y: T.shadowBtn.y)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: T.transitionFast), value: configuration.isPressed)
    }
}

/// Ghost variant — sage outline on transparent.
struct TallyGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: T.textBase, weight: .bold))
            .foregroundColor(C.sage)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, T.space6)
            .background(
                RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                    .stroke(C.sage, lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: T.transitionFast), value: configuration.isPressed)
    }
}

/// Brand text-field shell — white card, rule border, sage focus highlight (focus via .focused).
struct TallyInputModifier: ViewModifier {
    var focused: Bool = false
    func body(content: Content) -> some View {
        content
            .font(.system(size: T.textBase))
            .foregroundColor(C.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(C.white)
            .overlay(
                RoundedRectangle(cornerRadius: T.radiusMd, style: .continuous)
                    .stroke(focused ? C.sage : C.rule, lineWidth: focused ? 2 : 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: T.radiusMd, style: .continuous))
    }
}

extension View {
    func tallyInput(focused: Bool = false) -> some View {
        modifier(TallyInputModifier(focused: focused))
    }
}

// MARK: - Example ViewModifiers for Card and Pill Styles

extension View {
    /// Applies a card style with background, corner radius, and shadow
    func cardStyle() -> some View {
        self
            .padding()
            .background(C.cardBackground)
            .cornerRadius(T.radiusMd)
            .shadow(color: T.shadowMd.color, radius: T.shadowMd.radius, x: T.shadowMd.x, y: T.shadowMd.y)
    }
    
    /// Applies a pill style with background color and rounded capsule shape
    func pillStyle(background: Color = C.primary, foreground: Color = .white) -> some View {
        self
            .padding(.horizontal, T.spacingMd)
            .padding(.vertical, T.spacingSm)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(Capsule())
            .shadow(color: T.shadowSm.color, radius: T.shadowSm.radius, x: T.shadowSm.x, y: T.shadowSm.y)
    }
}

// MARK: - Helper Functions

func fmt(_ amount: Double, currency: Currency = .gbp) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency.rawValue
    formatter.maximumFractionDigits = 2
    let fallback = "\(currency.symbol)0.00"
    return formatter.string(from: NSNumber(value: amount)) ?? fallback
}

func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    return formatter.string(from: date)
}

/// Evaluate an amount string. Accepts plain numbers (`12.99`) or simple
/// `+ - * / ( )` expressions (`12.99 + 5.50`, `(1+2)*3.5`). Returns nil on
/// parse error. Strips currency symbols and grouping commas first.
func evaluateAmountExpression(_ input: String) -> Double? {
    let cleaned = input
        .trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "£", with: "")
        .replacingOccurrences(of: "$", with: "")
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "×", with: "*")
        .replacingOccurrences(of: "÷", with: "/")
    guard !cleaned.isEmpty else { return nil }

    // Fast path: plain decimal.
    if let d = Double(cleaned) { return d.isFinite ? d : nil }

    return ShuntingYard.evaluate(cleaned)
}

/// Tiny shunting-yard evaluator used by `evaluateAmountExpression`.
/// Safe by construction — refuses any character outside `0-9 . + - * / ( )`,
/// rejects unbalanced parens, divide-by-zero, and trailing operators.
private enum ShuntingYard {
    enum Token { case num(Double), op(Character), lp, rp }

    static func evaluate(_ input: String) -> Double? {
        guard let tokens = tokenize(input),
              let rpn = toRPN(tokens) else { return nil }
        return eval(rpn)
    }

    static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        var buf = ""
        var prevIsValue = false
        func flushNumber() -> Bool {
            guard !buf.isEmpty else { return true }
            guard let n = Double(buf) else { return false }
            tokens.append(.num(n))
            buf = ""
            prevIsValue = true
            return true
        }
        for ch in s {
            switch ch {
            case " ", "\t": continue
            case "0"..."9", ".":
                buf.append(ch)
            case "(":
                if !buf.isEmpty { return nil }
                tokens.append(.lp); prevIsValue = false
            case ")":
                if !flushNumber() { return nil }
                tokens.append(.rp); prevIsValue = true
            case "+", "-", "*", "/":
                if !flushNumber() { return nil }
                if (ch == "-" || ch == "+") && !prevIsValue {
                    tokens.append(.num(0))   // unary: turn -x into 0-x
                }
                tokens.append(.op(ch))
                prevIsValue = false
            default:
                return nil
            }
        }
        if !flushNumber() { return nil }
        return tokens
    }

    static func precedence(_ op: Character) -> Int {
        op == "*" || op == "/" ? 2 : 1
    }

    static func toRPN(_ tokens: [Token]) -> [Token]? {
        var output: [Token] = []
        var stack: [Token] = []
        for token in tokens {
            switch token {
            case .num: output.append(token)
            case .op(let op):
                while let top = stack.last, case .op(let topOp) = top, precedence(topOp) >= precedence(op) {
                    output.append(stack.removeLast())
                }
                stack.append(.op(op))
            case .lp:
                stack.append(.lp)
            case .rp:
                var found = false
                while let top = stack.last {
                    if case .lp = top { stack.removeLast(); found = true; break }
                    output.append(stack.removeLast())
                }
                if !found { return nil }
            }
        }
        while let top = stack.popLast() {
            if case .lp = top { return nil }
            output.append(top)
        }
        return output
    }

    static func eval(_ rpn: [Token]) -> Double? {
        var stack: [Double] = []
        for token in rpn {
            switch token {
            case .num(let v): stack.append(v)
            case .op(let op):
                guard stack.count >= 2 else { return nil }
                let b = stack.removeLast()
                let a = stack.removeLast()
                switch op {
                case "+": stack.append(a + b)
                case "-": stack.append(a - b)
                case "*": stack.append(a * b)
                case "/": guard b != 0 else { return nil }; stack.append(a / b)
                default:  return nil
                }
            case .lp, .rp: return nil
            }
        }
        guard stack.count == 1, stack[0].isFinite else { return nil }
        return stack[0]
    }
}

extension DateFormatter {
    static let tallyExportStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Exchange Rate Service

/// Fetches the latest GBP→USD rate.
///
/// Default path: calls the Tally backend at `https://logitude.app/tally/api/usd-rate`,
/// which is expected to return JSON of the form `{"rate": 1.27, "asOf": "2026-06-16"}`.
/// If that fails (e.g. early development before backend is live), falls back to
/// the public `exchangerate.host` API.
enum ExchangeRateService {
    static let tallyBackendURL = URL(string: "https://logitude.app/tally/api/usd-rate")!
    static let fallbackURL = URL(string: "https://api.exchangerate.host/latest?base=GBP&symbols=USD")!

    struct TallyResponse: Decodable { let rate: Double }
    struct FallbackResponse: Decodable { let rates: [String: Double] }

    static func latestUSDPerGBP() async -> Double? {
        if let r = await fetch(tallyBackendURL, decode: TallyResponse.self)?.rate {
            return r
        }
        if let payload = await fetch(fallbackURL, decode: FallbackResponse.self),
           let r = payload.rates["USD"] {
            return r
        }
        return nil
    }

    private static func fetch<T: Decodable>(_ url: URL, decode: T.Type) async -> T? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - PDF Tax-year summary

/// Renders an A4 portrait PDF summarising the active tax year — profile,
/// income, expenses (split allowable/disallowable), VAT estimate, income
/// tax + NI estimate, and the four MTD-IT quarters. Returns the file URL
/// in the temp directory, ready to hand to ShareLink.
enum TaxYearPDF {
    static func build(taxYear: Int,
                      profile: UserProfile,
                      taxCode: String,
                      entries: [Entry],
                      usdRate: Double) -> URL? {
        let income = entries.filter { $0.type == .income }
            .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
        let allowable = entries.filter { $0.type == .expense && $0.resolvedAllowable }
            .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
        let disallowable = entries.filter { $0.type == .expense && !$0.resolvedAllowable }
            .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
        let profit = income - allowable
        let pa = Double(parseTaxCode(taxCode) ?? 12_570)
        let incomeTax = estimateIncomeTaxRefined(entries: entries,
                                                 allowableExpenses: allowable,
                                                 personalAllowance: pa,
                                                 usdRate: usdRate)
        let ni = estimateClass4NI(on: profit)

        // A4 portrait at 72dpi = 595 x 842 pt.
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = 48

            draw("Tally — Tax year \(taxYear)/\(taxYear + 1)",
                 at: CGPoint(x: 48, y: y), font: .systemFont(ofSize: 22, weight: .bold))
            y += 32
            draw("Generated \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))",
                 at: CGPoint(x: 48, y: y), font: .systemFont(ofSize: 10), color: .gray)
            y += 28

            // Profile
            draw("Profile", at: CGPoint(x: 48, y: y), font: .systemFont(ofSize: 14, weight: .semibold))
            y += 18
            for line in [
                "Name: \(profile.name.isEmpty ? "—" : profile.name)",
                "NI number: \(profile.niNumber.isEmpty ? "—" : profile.niNumber)",
                "Tax code: \(taxCode)",
                "Personal allowance: \(fmt(pa))"
            ] {
                draw(line, at: CGPoint(x: 48, y: y), font: .systemFont(ofSize: 11))
                y += 16
            }
            y += 12

            // Totals
            draw("Year totals", at: CGPoint(x: 48, y: y), font: .systemFont(ofSize: 14, weight: .semibold))
            y += 18
            for row in [
                ("Income",                 fmt(income)),
                ("Allowable expenses",     fmt(allowable)),
                ("Disallowable expenses",  fmt(disallowable)),
                ("Taxable profit",         fmt(profit)),
                ("Income Tax (est.)",      fmt(incomeTax)),
                ("Class 4 NI (est.)",      fmt(ni))
            ] {
                drawRow(label: row.0, value: row.1, y: y)
                y += 16
            }
            y += 12

            // Quarters
            draw("MTD-IT quarters", at: CGPoint(x: 48, y: y), font: .systemFont(ofSize: 14, weight: .semibold))
            y += 18
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Europe/London") ?? .current
            let yearStart = cal.date(from: DateComponents(year: taxYear, month: 4, day: 6)) ?? Date()
            for i in 0..<4 {
                guard let qStart = cal.date(byAdding: .month, value: i * 3, to: yearStart),
                      let qEnd   = cal.date(byAdding: .month, value: (i + 1) * 3, to: yearStart) else { continue }
                let qIncome = entries.filter { $0.type == .income && $0.date >= qStart && $0.date < qEnd }
                    .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
                let qExp = entries.filter { $0.type == .expense && $0.resolvedAllowable && $0.date >= qStart && $0.date < qEnd }
                    .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
                drawRow(label: "Q\(i+1) profit", value: fmt(qIncome - qExp), y: y)
                y += 16
            }
            y += 16

            draw("Estimates only. Tally does not file with HMRC.",
                 at: CGPoint(x: 48, y: y), font: .systemFont(ofSize: 9), color: .gray)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-tax-\(taxYear)-\(taxYear + 1).pdf")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func draw(_ text: String, at point: CGPoint,
                             font: UIFont, color: UIColor = .label) {
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: point, withAttributes: attr)
    }

    private static func drawRow(label: String, value: String, y: CGFloat) {
        draw(label, at: CGPoint(x: 48, y: y), font: .systemFont(ofSize: 11))
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        let str = value as NSString
        let size = str.size(withAttributes: attr)
        str.draw(at: CGPoint(x: 595 - 48 - size.width, y: y), withAttributes: attr)
    }
}

// MARK: - HMRC Deadline notifications

/// Schedules (or cancels) UK self-assessment deadline reminders:
///   - 31 January: balancing payment & online return
///   - 31 July: second payment on account
/// Three reminders per deadline: 30 days, 7 days, on the day.
enum HMRCDeadlineNotifications {
    static let categoryId = "tally.hmrc.deadline"

    /// Requests notification permission (idempotent — system caches the prompt
    /// state). Returns whether the app may post notifications.
    static func requestAuthorisation() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        do {
            return try await centre.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    /// Wipes any previously-scheduled deadline reminders, then re-schedules
    /// the next 12 months of deadlines.
    static func reschedule(from referenceDate: Date = Date()) {
        let centre = UNUserNotificationCenter.current()
        centre.getPendingNotificationRequests { requests in
            let ours = requests.filter { $0.identifier.hasPrefix("hmrc-") }.map(\.identifier)
            centre.removePendingNotificationRequests(withIdentifiers: ours)

            for date in upcomingDeadlines(after: referenceDate) {
                schedule(for: date, label: deadlineLabel(date), centre: centre)
            }
        }
    }

    /// Removes every scheduled HMRC deadline reminder.
    static func cancelAll() {
        let centre = UNUserNotificationCenter.current()
        centre.getPendingNotificationRequests { requests in
            let ours = requests.filter { $0.identifier.hasPrefix("hmrc-") }.map(\.identifier)
            centre.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    /// The next two deadlines (31 Jan and 31 Jul) after `from`.
    private static func upcomingDeadlines(after from: Date) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let year = cal.component(.year, from: from)
        let candidates = (year...(year + 1)).flatMap { y -> [Date] in
            [cal.date(from: DateComponents(year: y, month: 1, day: 31, hour: 9))!,
             cal.date(from: DateComponents(year: y, month: 7, day: 31, hour: 9))!]
        }
        return candidates.filter { $0 > from }.prefix(2).map { $0 }
    }

    private static func deadlineLabel(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let m = cal.component(.month, from: date)
        return m == 1 ? "Self-assessment balancing payment"
                      : "Second payment on account"
    }

    private static func schedule(for deadline: Date, label: String,
                                 centre: UNUserNotificationCenter) {
        let offsets: [(days: Int, prefix: String)] = [
            (-30, "30 days"),
            (-7,  "7 days"),
            (0,   "today")
        ]
        for offset in offsets {
            guard let fireDate = Calendar.current.date(byAdding: .day, value: offset.days, to: deadline),
                  fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = label
            content.body  = "HMRC deadline \(offset.prefix == "today" ? "is today" : "in \(offset.prefix)") (31 \(Calendar.current.component(.month, from: deadline) == 1 ? "Jan" : "Jul"))."
            content.sound = .default

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = "hmrc-\(ISO8601DateFormatter().string(from: deadline))-\(offset.prefix)"
            centre.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}

// MARK: - Haptics

/// Thin wrapper around UIKit's feedback generators. Each helper is safe to
/// call from any thread but generators run best when triggered close to the
/// taptic event itself, so we instantiate fresh each call.
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Sample data

/// Builds ~30 representative entries spread across the active tax year so
/// the Dashboard / charts / Tax Summary populate immediately for testing.
enum SampleData {
    static func build(taxYear: Int) -> [Entry] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let yearStart = cal.date(from: DateComponents(year: taxYear, month: 4, day: 6)) ?? Date()
        func d(_ monthOffset: Int, _ day: Int) -> Date {
            cal.date(byAdding: DateComponents(month: monthOffset, day: day - 6), to: yearStart) ?? Date()
        }

        let cat: (String, String) -> Category = { name, color in
            Category(id: UUID(), name: name, colorName: color)
        }

        let income: [Entry] = [
            entry(date: d(0, 28),  desc: "Freelance retainer",   amount: 2500, type: .income,  cat: cat("Salary", "green"),  currency: .gbp),
            entry(date: d(1, 30),  desc: "Freelance retainer",   amount: 2500, type: .income,  cat: cat("Salary", "green"),  currency: .gbp),
            entry(date: d(2, 30),  desc: "Project — Acme Ltd",   amount: 3800, type: .income,  cat: cat("Salary", "green"),  currency: .gbp),
            entry(date: d(3, 30),  desc: "Project — Beta Corp",  amount: 1200, type: .income,  cat: cat("Salary", "green"),  currency: .usd),
            entry(date: d(5, 30),  desc: "Freelance retainer",   amount: 2750, type: .income,  cat: cat("Salary", "green"),  currency: .gbp),
            entry(date: d(8, 30),  desc: "Workshop fees",        amount: 950,  type: .income,  cat: cat("Salary", "green"),  currency: .gbp),
        ]

        let expenses: [Entry] = [
            entry(date: d(0, 12),  desc: "Namecheap domain",          amount: 12.99, type: .expense, cat: cat("Domain names",     "sage"),      currency: .gbp, duration: .oneYear, vat: .standard),
            entry(date: d(0, 15),  desc: "Hetzner VPS",               amount: 14.50, type: .expense, cat: cat("Web hosting",      "sageLight"), currency: .gbp, recurrence: .monthly, vat: .standard),
            entry(date: d(0, 18),  desc: "Stripe SSL",                amount: 95.00, type: .expense, cat: cat("SSL Certificates", "amber"),     currency: .usd, duration: .oneYear),
            entry(date: d(1, 8),   desc: "OpenAI usage",              amount: 42.30, type: .expense, cat: cat("GenAI",            "mint"),      currency: .usd, recurrence: .monthly, vat: .exempt),
            entry(date: d(1, 22),  desc: "Office coffee + sandwich",  amount: 8.40,  type: .expense, cat: cat("Food",             "orange"),    currency: .gbp, vat: .reduced),
            entry(date: d(2, 4),   desc: "Train to client meeting",   amount: 32.50, type: .expense, cat: cat("Transport",        "blue"),      currency: .gbp, vat: .zeroRated),
            entry(date: d(2, 14),  desc: "Notion subscription",       amount: 8.00,  type: .expense, cat: cat("GenAI",            "mint"),      currency: .usd, recurrence: .monthly),
            entry(date: d(3, 1),   desc: "Cloudflare Pro",            amount: 20.00, type: .expense, cat: cat("Web hosting",      "sageLight"), currency: .usd, recurrence: .monthly, vat: .standard),
            entry(date: d(3, 19),  desc: "Anthropic Claude",          amount: 30.00, type: .expense, cat: cat("GenAI",            "mint"),      currency: .usd, recurrence: .monthly),
            entry(date: d(4, 5),   desc: "Adobe CC",                  amount: 30.34, type: .expense, cat: cat("GenAI",            "mint"),      currency: .gbp, recurrence: .monthly, vat: .standard),
            entry(date: d(5, 11),  desc: "GitHub Copilot",            amount: 10.00, type: .expense, cat: cat("GenAI",            "mint"),      currency: .usd, recurrence: .monthly),
            entry(date: d(6, 3),   desc: "Quarterly tax payment",     amount: 1280,  type: .tax,     cat: cat("Tax",              "red"),       currency: .gbp),
            entry(date: d(7, 17),  desc: "Conference ticket",         amount: 180,   type: .expense, cat: cat("General",          "primary"),   currency: .gbp, vat: .standard),
            entry(date: d(8, 22),  desc: "Travel insurance",          amount: 24.00, type: .expense, cat: cat("General",          "primary"),   currency: .gbp, vat: .exempt),
            entry(date: d(9, 8),   desc: "Lunch with client",         amount: 47.50, type: .expense, cat: cat("Food",             "orange"),    currency: .gbp, vat: .standard),
            entry(date: d(10, 14), desc: "Domain renewal",            amount: 12.99, type: .expense, cat: cat("Domain names",     "sage"),      currency: .gbp, duration: .oneYear, vat: .standard),
            entry(date: d(11, 1),  desc: "Quarterly tax payment",     amount: 1480,  type: .tax,     cat: cat("Tax",              "red"),       currency: .gbp),
        ]
        return (income + expenses).sorted { $0.date < $1.date }
    }

    private static func entry(date: Date,
                              desc: String,
                              amount: Double,
                              type: Entry.EntryType,
                              cat: Category,
                              currency: Currency,
                              recurrence: Recurrence? = nil,
                              duration: Duration? = nil,
                              vat: VATRate? = nil,
                              vendor: String? = nil) -> Entry {
        Entry(
            id: UUID(),
            date: date,
            description: desc,
            amount: amount,
            type: type,
            category: cat,
            recurrence: recurrence,
            duration: duration,
            attachments: nil,
            currency: currency,
            parentEntryId: nil,
            lastGeneratedAt: nil,
            notes: nil,
            vatRate: vat,
            vendor: vendor
        )
    }
}

// MARK: - CSV Export

enum EntryCSV {
    /// RFC 4180-ish: header row + one row per entry. Strings containing commas,
    /// quotes, or newlines are double-quoted with internal quotes doubled.
    static func makeCSV(entries: [Entry], usdRate: Double) -> String {
        let header = "Date,Description,Type,Category,Amount,Currency,Amount (GBP),Recurrence,Duration,Commitment Multiplier,Total (GBP),Attachments\n"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        let rows = entries.map { e -> String in
            let dateStr = formatter.string(from: e.date)
            let amount = String(format: "%.2f", e.amount)
            let amountGBP = String(format: "%.2f", e.amountInGBP(usdRate: usdRate))
            let totalGBP = String(format: "%.2f", e.totalAmountInGBP(usdRate: usdRate))
            let multiplier = String(format: "%.4f", e.commitmentMultiplier)
            let attachmentCount = e.attachments?.count ?? 0
            let fields: [String] = [
                dateStr,
                e.description,
                e.type.rawValue,
                e.category.name,
                amount,
                e.resolvedCurrency.rawValue,
                amountGBP,
                e.recurrence?.rawValue ?? "",
                e.duration?.rawValue ?? "",
                multiplier,
                totalGBP,
                String(attachmentCount)
            ]
            return fields.map(escape).joined(separator: ",")
        }
        return header + rows.joined(separator: "\n") + "\n"
    }

    nonisolated private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Write `csv` to a temp file with a friendly filename and return its URL.
    static func writeToTemp(csv: String, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(filename)
        try csv.data(using: .utf8)?.write(to: url)
        return url
    }
}

func parseTaxCode(_ code: String) -> Int? {
    // UK tax code is typically digits followed by a letter, e.g. 1257L.
    // Personal allowance is the digit portion × 10.
    // Special codes like BR / D0 / D1 / NT have no allowance — return 0.
    let upper = code.uppercased().trimmingCharacters(in: .whitespaces)
    if ["BR", "D0", "D1", "D2", "NT", "0T"].contains(upper) {
        return 0
    }
    let digits = upper.filter { $0.isNumber }
    guard !digits.isEmpty, let number = Int(digits) else { return nil }
    return number * 10
}

/// Common UK tax-code presets with a one-line explanation for the lookup picker.
struct TaxCodePreset: Identifiable {
    var id: String { code }
    let code: String
    let description: String
}

let commonTaxCodes: [TaxCodePreset] = [
    .init(code: "1257L", description: "Standard personal allowance (£12,570)"),
    .init(code: "BR",    description: "Basic rate on all income — no allowance"),
    .init(code: "D0",    description: "Higher rate on all income (40%)"),
    .init(code: "D1",    description: "Additional rate on all income (45%)"),
    .init(code: "NT",    description: "No tax deducted (rare)"),
    .init(code: "0T",    description: "No personal allowance, normal bands"),
    .init(code: "K475",  description: "Negative allowance — owe HMRC on £4,750"),
]

/// UK income-tax bands for 2025/26 (England & NI rates).
struct TaxBand: Identifiable {
    var id: String { name }
    let name: String
    let upTo: Double?     // nil = no upper limit
    let rate: Double      // 0.20 = 20%
}

let ukIncomeTaxBands2025_26: [TaxBand] = [
    .init(name: "Personal allowance", upTo: 12_570,  rate: 0.0),
    .init(name: "Basic rate",         upTo: 50_270,  rate: 0.20),
    .init(name: "Higher rate",        upTo: 125_140, rate: 0.40),
    .init(name: "Additional rate",    upTo: nil,     rate: 0.45),
]

/// Estimated VAT *included* in a gross expense, at the UK standard rate (20%).
/// Used as a fallback when the entry doesn't carry an explicit VAT field.
///   Net  = gross / 1.20
///   VAT  = gross - net = gross / 6
func estimateVATIncluded(in gross: Double) -> Double {
    gross / 6.0
}

/// Estimated UK Income Tax owed on a taxable profit, 2025/26 bands.
/// `personalAllowance` is the amount taxed at 0% (typically £12,570 for 1257L,
/// 0 for BR / D0 / D1).
func estimateIncomeTax(on profit: Double, personalAllowance: Double) -> Double {
    let pa = max(personalAllowance, 0)
    let basicEnd: Double = 50_270
    let higherEnd: Double = 125_140
    let inBasic       = max(min(profit, basicEnd)  - max(pa, 0), 0)
    let inHigher      = max(min(profit, higherEnd) - basicEnd,    0)
    let inAdditional  = max(profit - higherEnd, 0)
    return inBasic * 0.20 + inHigher * 0.40 + inAdditional * 0.45
}

/// 2025/26 dividend allowance and rates.
let ukDividendAllowance2025_26: Double = 500
let ukDividendBasic = 0.0875
let ukDividendHigher = 0.3375
let ukDividendAdditional = 0.3935

/// Personal Savings Allowance — depends on band but use the basic-rate £1,000
/// for the estimate. Refine when we add band-stacking later.
let ukSavingsAllowance2025_26: Double = 1_000

/// Refined Income Tax estimate that:
///   - Excludes PAYE-already-taxed income entirely (treats as tax paid at source)
///   - Sums freelance + rental as ordinary income against bands
///   - Applies dividend allowance + dividend bands on top of ordinary income
///   - Applies savings allowance to interest, then ordinary rates
///   - Self-assessment context: returns the *additional* tax owed via SA
func estimateIncomeTaxRefined(entries: [Entry],
                              allowableExpenses: Double,
                              personalAllowance pa: Double,
                              usdRate: Double) -> Double {
    var ordinary: Double = 0   // freelance, rental, other
    var dividends: Double = 0
    var interest: Double = 0

    for e in entries where e.type == .income {
        let gbp = e.totalAmountInGBP(usdRate: usdRate)
        switch e.resolvedIncomeType {
        case .paye:       continue        // already taxed via PAYE
        case .dividend:   dividends += gbp
        case .interest:   interest  += gbp
        case .freelance, .rental, .other:
            ordinary += gbp
        }
    }

    // Ordinary income: freelance + rental + other, less allowable expenses
    let ordinaryProfit = max(ordinary - allowableExpenses, 0)
    let ordinaryTax = estimateIncomeTax(on: ordinaryProfit, personalAllowance: pa)

    // Savings interest: ignore up to £1,000 (basic-rate PSA), then ordinary rates
    let taxableInterest = max(interest - ukSavingsAllowance2025_26, 0)
    let interestTax = estimateIncomeTax(on: ordinaryProfit + taxableInterest,
                                        personalAllowance: pa) - ordinaryTax

    // Dividends: £500 allowance, then dividend bands. We stack on top of
    // ordinary income — band thresholds are absolute (basic ends 50,270 etc).
    let taxableDividends = max(dividends - ukDividendAllowance2025_26, 0)
    let base = ordinaryProfit + taxableInterest
    let basicCap: Double = 50_270
    let higherCap: Double = 125_140

    let divInBasic      = max(min(base + taxableDividends, basicCap)  - max(base, basicCap == 0 ? 0 : basicCap), 0)
    // Re-compute more carefully band-by-band:
    let remainingBasic  = max(basicCap  - base, 0)
    let remainingHigher = max(higherCap - max(base, basicCap), 0)
    let divBasic      = min(taxableDividends, remainingBasic)
    let divHigher     = min(max(taxableDividends - divBasic, 0), remainingHigher)
    let divAdditional = max(taxableDividends - divBasic - divHigher, 0)
    _ = divInBasic  // unused (kept for clarity above)
    let dividendTax = divBasic * ukDividendBasic
                    + divHigher * ukDividendHigher
                    + divAdditional * ukDividendAdditional

    return ordinaryTax + max(interestTax, 0) + dividendTax
}

/// Estimated Class 4 National Insurance owed on a self-employed profit,
/// 2025/26 bands (6% main, 2% upper).
func estimateClass4NI(on profit: Double) -> Double {
    let lower: Double = 12_570
    let upper: Double = 50_270
    let inMain  = max(min(profit, upper) - lower, 0)
    let inUpper = max(profit - upper, 0)
    return inMain * 0.06 + inUpper * 0.02
}

/// Class 4 NI bands for self-employed, 2025/26.
struct NIBand: Identifiable {
    var id: String { name }
    let name: String
    let upTo: Double?
    let rate: Double
}

let ukClass4NIBands2025_26: [NIBand] = [
    .init(name: "Below lower limit",  upTo: 12_570, rate: 0.0),
    .init(name: "Main rate",          upTo: 50_270, rate: 0.06),
    .init(name: "Upper rate",         upTo: nil,    rate: 0.02),
]

// MARK: - Main View

struct UkExpenseTrackerView: View {
    // Data storage
    @AppStorage("entriesData") private var entriesData: Data = Data()
    @AppStorage("taxYear") private var taxYear: Int = currentTaxYear()
    @AppStorage("taxCode") private var taxCode: String = "1257L"
    @AppStorage("usdRate") private var usdRate: Double = 1.25
    @AppStorage("usdRateUpdatedAt") private var usdRateUpdatedAt: Double = 0
    @AppStorage("userProfileData") private var profileData: Data = Data()
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("customCategoriesData") private var customCategoriesData: Data = Data()

    @State private var entries: [Entry] = []
    @State private var selectedTab = 0
    @State private var showEntryModal = false
    @State private var showSettings = false
    @State private var showWhatsNew = false
    @State private var showFAQ = false
    @State private var editingEntry: Entry?
    @State private var toastMessage: String?
    @State private var toastTimer: Timer?

    private var customCategoryNames: [String] {
        guard !customCategoriesData.isEmpty,
              let decoded = try? JSONDecoder().decode([String].self, from: customCategoriesData)
        else { return [] }
        return decoded
    }

    /// Entries whose date falls inside the currently-selected tax year.
    private var entriesForSelectedYear: [Entry] {
        entries.filter { dateIsInTaxYear($0.date, taxYear: taxYear) }
    }

    /// Years that have at least one entry, plus the current year — used to keep
    /// the picker compact rather than dumping 20 years of empty options.
    private var availableTaxYears: [Int] {
        let years = Set(entries.map { calendarTaxYear(for: $0.date) })
            .union([currentTaxYear(), taxYear])
        return years.sorted(by: >)
    }

    // Authentication state managed by LoginManager
    @StateObject private var loginManager = LoginManager()

    var body: some View {
        Group {
            if loginManager.step == .authenticated {
                NavigationView {
                    VStack(spacing: 0) {
                        Picker(selection: $selectedTab, label: Text("Select Tab")) {
                            Text("Overview").tag(0)
                            Text("Expenses").tag(1)
                            Text("Income").tag(2)
                            Text("Tax").tag(3)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding()
                        .background(C.paper)

                        Divider()

                        // Tab content — all aggregates use the year-filtered slice
                        Group {
                            switch selectedTab {
                            case 0:
                                DashboardView(entries: entriesForSelectedYear,
                                              allEntries: entries,
                                              taxYear: taxYear,
                                              usdRate: usdRate,
                                              onEditEntry: editEntry)
                            case 1:
                                EntryListView(
                                    entries: entriesForSelectedYear.filter { $0.type == .expense },
                                    title: "Expenses",
                                    usdRate: usdRate,
                                    onEdit: editEntry,
                                    onAddNew: addNewEntry,
                                    onDuplicate: duplicateEntry,
                                    onDelete: deleteEntry,
                                    onRefresh: refreshFromUser
                                )
                            case 2:
                                EntryListView(
                                    entries: entriesForSelectedYear.filter { $0.type == .income },
                                    title: "Income",
                                    usdRate: usdRate,
                                    onEdit: editEntry,
                                    onAddNew: addNewEntry,
                                    onDuplicate: duplicateEntry,
                                    onDelete: deleteEntry,
                                    onRefresh: refreshFromUser
                                )
                            case 3:
                                SummaryView(entries: entriesForSelectedYear, taxYear: taxYear, taxCode: taxCode, usdRate: usdRate)
                            default:
                                Text("Unknown Tab")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                        ToolbarItem(placement: .principal) {
                            Menu {
                                ForEach(availableTaxYears, id: \.self) { year in
                                    Button {
                                        taxYear = year
                                    } label: {
                                        if year == taxYear {
                                            Label("\(String(year))/\(String(year + 1))", systemImage: "checkmark")
                                        } else {
                                            Text("\(String(year))/\(String(year + 1))")
                                        }
                                    }
                                }
                                Divider()
                                Button {
                                    taxYear = currentTaxYear()
                                } label: {
                                    Label("Current tax year", systemImage: "calendar")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Tax year \(taxYearShortLabel(taxYear))")
                                        .font(.system(size: T.textSm, weight: .semibold))
                                    Image(systemName: "chevron.down")
                                        .font(.caption2.weight(.bold))
                                }
                                .foregroundColor(C.ink)
                            }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            HStack(spacing: T.space3) {
                                Menu {
                                    Button {
                                        showWhatsNew = true
                                    } label: {
                                        Label("What's New", systemImage: "sparkles")
                                    }
                                    Button {
                                        showFAQ = true
                                    } label: {
                                        Label("FAQ", systemImage: "questionmark.circle")
                                    }
                                } label: {
                                    Image(systemName: "questionmark.circle")
                                }
                                Button(action: addNewEntry) {
                                    Image(systemName: "plus")
                                }
                            }
                        }
                    }
                    .tint(C.sage)
                    .onAppear {
                        loadEntries()
                        refreshExchangeRateIfStale()
                    }
                    .sheet(isPresented: $showEntryModal) {
                        EntryModalView(entry: $editingEntry,
                                       usdRate: usdRate,
                                       customCategoryNames: customCategoryNames,
                                       onSave: saveEntry,
                                       onCancel: cancelEntry,
                                       onAddCustomCategory: addCustomCategory)
                    }
                    .sheet(isPresented: $showSettings) {
                        SettingsView(
                            profileData: $profileData,
                            entriesData: $entriesData,
                            appearanceMode: $appearanceMode,
                            taxCode: $taxCode,
                            customCategoriesData: $customCategoriesData,
                            usdRate: $usdRate,
                            usdRateUpdatedAt: $usdRateUpdatedAt,
                            entries: entries,
                            taxYear: taxYear,
                            onLoadSampleData: loadSampleData,
                            loginManager: loginManager
                        )
                    }
                    .sheet(isPresented: $showWhatsNew) { WhatsNewView() }
                    .sheet(isPresented: $showFAQ) { FAQView() }
                    .overlay {
                        if let message = toastMessage {
                            ToastView(message: message)
                                .transition(.opacity)
                                .zIndex(1)
                        }
                    }
                }
            } else {
                AuthFlowView(loginManager: loginManager)
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
    }

    // MARK: - Actions

    private func loadEntries() {
        guard !entriesData.isEmpty else {
            entries = []
            return
        }
        do {
            entries = try JSONDecoder().decode([Entry].self, from: entriesData)
        } catch {
            entries = []
            showToast("Failed to load entries")
            return
        }
        materialiseRecurringIfNeeded()
    }

    /// Generates child entries for any recurring templates whose next cycle
    /// has elapsed, persists the result, and notifies the user via a toast.
    private func materialiseRecurringIfNeeded() {
        let addedCount = autoGenerateRecurring(entries: &entries)
        guard addedCount > 0 else { return }
        saveEntries()
        showToast("Added \(addedCount) recurring \(addedCount == 1 ? "entry" : "entries")")
    }

    /// Refreshes the USD rate once per 12-hour window. Silent on failure —
    /// the previously cached rate keeps working.
    private func refreshExchangeRateIfStale() {
        let cutoff: TimeInterval = 12 * 60 * 60
        let age = Date().timeIntervalSince1970 - usdRateUpdatedAt
        guard age > cutoff else { return }
        Task {
            if let rate = await ExchangeRateService.latestUSDPerGBP(), rate > 0 {
                await MainActor.run {
                    usdRate = rate
                    usdRateUpdatedAt = Date().timeIntervalSince1970
                }
            }
        }
    }

    private func saveEntries() {
        do {
            let data = try JSONEncoder().encode(entries)
            entriesData = data
        } catch {
            showToast("Failed to save entries")
        }
    }

    private func addNewEntry() {
        editingEntry = Entry(
            id: UUID(),
            date: Date(),
            description: "",
            amount: 0.0,
            type: .expense,
            category: Category(id: UUID(), name: "General", colorName: "primary"),
            recurrence: nil,
            duration: nil,
            attachments: nil
        )
        showEntryModal = true
    }

    private func editEntry(_ entry: Entry) {
        editingEntry = entry
        showEntryModal = true
    }

    /// Open a fresh draft pre-filled from `entry`. Attachments + auto-gen
    /// lineage are intentionally dropped so the duplicate is a true new entry.
    /// Persists a user-created category name. No-op if it's already in the list.
    private func addCustomCategory(_ name: String) {
        var list = customCategoryNames
        guard !list.contains(name) else { return }
        list.append(name)
        if let data = try? JSONEncoder().encode(list) {
            customCategoriesData = data
        }
    }

    /// Wired to the SwiftUI .refreshable modifier on EntryListView. Re-runs
    /// recurring auto-gen + USD rate refresh so pulling down catches any
    /// brand-new cycles or a stale FX figure.
    @MainActor
    private func refreshFromUser() async {
        materialiseRecurringIfNeeded()
        if let rate = await ExchangeRateService.latestUSDPerGBP(), rate > 0 {
            usdRate = rate
            usdRateUpdatedAt = Date().timeIntervalSince1970
        }
        Haptics.impact()
    }

    private func loadSampleData() {
        let sample = SampleData.build(taxYear: taxYear)
        entries.append(contentsOf: sample)
        entries.sort { $0.date < $1.date }
        saveEntries()
        Haptics.success()
        showToast("Loaded \(sample.count) sample entries")
    }

    private func duplicateEntry(_ entry: Entry) {
        Haptics.impact()
        var copy = entry
        copy.id = UUID()
        copy.date = Date()
        copy.attachments = nil
        copy.parentEntryId = nil
        copy.lastGeneratedAt = nil
        editingEntry = copy
        showEntryModal = true
    }

    private func deleteEntry(_ entry: Entry) {
        if let attachments = entry.attachments {
            for a in attachments { AttachmentStore.shared.delete(a) }
        }
        entries.removeAll { $0.id == entry.id }
        saveEntries()
        Haptics.warning()
    }

    private func saveEntry(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        saveEntries()
        showEntryModal = false
        Haptics.success()
        showToast("Entry saved")
    }

    private func cancelEntry() {
        showEntryModal = false
    }

    private func showToast(_ message: String) {
        toastMessage = message
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
            withAnimation {
                toastMessage = nil
            }
        }
    }
}

// MARK: - Child Views

struct DashboardView: View {
    var entries: [Entry]      // already filtered to the active tax year
    var allEntries: [Entry]   // unfiltered — feeds year-over-year comparisons
    var taxYear: Int
    var usdRate: Double
    var onEditEntry: ((Entry) -> Void)? = nil

    private var totalIncome: Double {
        entries.filter { $0.type == .income }
            .map { $0.totalAmountInGBP(usdRate: usdRate) }
            .reduce(0, +)
    }
    private var totalExpenses: Double {
        entries.filter { $0.type == .expense }
            .map { $0.totalAmountInGBP(usdRate: usdRate) }
            .reduce(0, +)
    }
    private var profit: Double { totalIncome - totalExpenses }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TallyPageHeader(title: "Dashboard", subtitle: "Tax year \(String(taxYear))/\(String(taxYear + 1))")

                VStack(spacing: T.space4) {
                    SummaryCard(label: "Taxable profit",
                                value: fmt(profit),
                                accent: profit >= 0 ? C.sage : C.alert,
                                style: .sage)
                    HStack(spacing: T.space4) {
                        SummaryCard(label: "Income",
                                    value: fmt(totalIncome),
                                    accent: C.sageLight,
                                    style: .plain)
                        SummaryCard(label: "Expenses",
                                    value: fmt(totalExpenses),
                                    accent: C.alert,
                                    style: .plain)
                    }
                    if entries.isEmpty {
                        Text("No entries yet — tap + to add your first.")
                            .font(.bodyText)
                            .foregroundColor(C.mid)
                            .frame(maxWidth: .infinity)
                            .padding(.top, T.space6)
                    } else {
                        ComparisonCardsRow(allEntries: allEntries,
                                           taxYear: taxYear,
                                           usdRate: usdRate)
                        RecentEntriesCard(entries: entries,
                                          usdRate: usdRate,
                                          onEdit: onEditEntry)
                        MonthlyProfitChart(entries: entries,
                                           taxYear: taxYear,
                                           usdRate: usdRate)
                        CategoryBreakdownChart(entries: entries,
                                               usdRate: usdRate)
                    }
                }
                .padding(.horizontal, T.space6)
                .padding(.bottom, T.space8)
            }
        }
        .background(C.paper)
    }
}

private struct SummaryCard: View {
    enum Style { case plain, sage, amber }
    let label: String
    let value: String
    let accent: Color
    var style: Style = .plain

    private var background: Color {
        switch style {
        case .plain: C.white
        case .sage: C.sagePale
        case .amber: C.amberPale
        }
    }
    private var border: Color {
        switch style {
        case .plain: C.rule
        case .sage: C.mint
        case .amber: C.amber.opacity(0.3)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.space2) {
            Text(label)
                .font(.dataLabel)
                .foregroundColor(C.mid)
            Text(value)
                .font(.heroNumber)
                .foregroundColor(accent)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(T.space5)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

/// Three derived estimate cards: VAT included in expenses, Income Tax owed,
/// and Class 4 NI owed. VAT splits into explicit (where the user declared
/// a rate) and estimated (where they didn't — 20% included is assumed).
private struct EstimatesGroup: View {
    let entries: [Entry]
    let profit: Double
    let expenses: Double
    let allowableExpenses: Double
    let personalAllowance: Double
    let usdRate: Double

    /// VAT calculated from entries that have an explicit VATRate.
    private var explicitVAT: Double {
        entries
            .filter { $0.type == .expense && $0.hasExplicitVAT }
            .compactMap { e -> Double? in
                guard let v = e.explicitVATIncluded else { return nil }
                let gbp = e.resolvedCurrency == .usd && usdRate > 0 ? v / usdRate : v
                return gbp
            }
            .reduce(0, +)
    }

    /// 20% estimate applied only to expenses without an explicit rate.
    private var estimatedVAT: Double {
        entries
            .filter { $0.type == .expense && !$0.hasExplicitVAT }
            .map { e in estimateVATIncluded(in: e.amountInGBP(usdRate: usdRate)) }
            .reduce(0, +)
    }

    private var totalVAT: Double { explicitVAT + estimatedVAT }

    var body: some View {
        VStack(spacing: T.space4) {
            VStack(alignment: .leading, spacing: T.space2) {
                SummaryCard(
                    label: "VAT in expenses",
                    value: fmt(totalVAT),
                    accent: C.amber,
                    style: .amber
                )
                HStack(spacing: T.space2) {
                    VATBreakdownChip(label: "Declared", amount: explicitVAT, color: C.sage)
                    VATBreakdownChip(label: "Estimated", amount: estimatedVAT, color: C.amber)
                }
                .padding(.horizontal, T.space2)
            }
            SummaryCard(
                label: "Income Tax due (est., excludes PAYE)",
                value: fmt(estimateIncomeTaxRefined(entries: entries,
                                                    allowableExpenses: allowableExpenses,
                                                    personalAllowance: personalAllowance,
                                                    usdRate: usdRate)),
                accent: C.alert,
                style: .plain
            )
            SummaryCard(
                label: "Class 4 NI due (est.)",
                value: fmt(estimateClass4NI(on: profit)),
                accent: C.sage,
                style: .plain
            )
            Text("Income Tax: PAYE entries excluded (already taxed at source). Dividends apply the £500 allowance then 8.75/33.75/39.35%. Savings interest gets the £1,000 PSA. VAT: Unspecified expenses assumed 20% included; pick a rate per entry to make it exact. NI: Class 4 on freelance/rental profit.")
                .font(.system(size: T.textXs))
                .foregroundColor(C.mid)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VATBreakdownChip: View {
    let label: String
    let amount: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.eyebrow)
                .foregroundColor(C.mid)
            Text(fmt(amount))
                .font(.system(size: T.textSm, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Up to 5 most recent entries (any type) for the active tax year, in a
/// compact card. Tapping a row opens it in the entry-edit sheet.
private struct RecentEntriesCard: View {
    let entries: [Entry]
    let usdRate: Double
    var onEdit: ((Entry) -> Void)?

    private var recent: [Entry] {
        Array(entries.sorted { $0.date > $1.date }.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.space3) {
            HStack {
                Text("Recent activity")
                    .font(.eyebrow)
                    .foregroundColor(C.mid)
                Spacer()
            }
            VStack(spacing: T.space2) {
                ForEach(recent) { entry in
                    HStack(spacing: T.space3) {
                        Text(shortDate(entry.date))
                            .font(.system(size: T.textXs, weight: .semibold, design: .monospaced))
                            .foregroundColor(C.mid)
                            .frame(width: 64, alignment: .leading)
                        Text(entry.description.isEmpty ? entry.category.name : entry.description)
                            .font(.system(size: T.textSm))
                            .foregroundColor(C.ink)
                            .lineLimit(1)
                        Spacer(minLength: T.space2)
                        Text((entry.type == .expense ? "−" : "+") +
                             fmt(entry.amount, currency: entry.resolvedCurrency))
                            .font(.system(size: T.textSm, weight: .bold))
                            .foregroundColor(entry.type == .expense ? C.alert : C.sageLight)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onEdit?(entry) }
                }
            }
        }
        .padding(T.space5)
        .background(C.white)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(C.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

/// Two side-by-side comparison cards:
///   "This month vs last month" of profit (calendar-month basis)
///   "This year vs last year" of profit (UK tax-year basis)
private struct ComparisonCardsRow: View {
    let allEntries: [Entry]
    let taxYear: Int
    let usdRate: Double

    fileprivate struct Comparison {
        let current: Double
        let previous: Double

        var delta: Double { current - previous }
        var pct: Double? {
            guard previous != 0 else { return nil }
            return (current - previous) / abs(previous)
        }
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        return c
    }

    private func profit(in range: ClosedRange<Date>) -> Double {
        let inRange = allEntries.filter { range.contains($0.date) }
        let inc = inRange.filter { $0.type == .income  }
            .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
        let exp = inRange.filter { $0.type == .expense && $0.resolvedAllowable }
            .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
        return inc - exp
    }

    private var monthComparison: Comparison {
        let now = Date()
        guard let curStart = cal.dateInterval(of: .month, for: now)?.start,
              let curEnd   = cal.date(byAdding: .month, value: 1, to: curStart),
              let prevStart = cal.date(byAdding: .month, value: -1, to: curStart) else {
            return Comparison(current: 0, previous: 0)
        }
        let curRange  = curStart...cal.date(byAdding: .second, value: -1, to: curEnd)!
        let prevRange = prevStart...cal.date(byAdding: .second, value: -1, to: curStart)!
        return Comparison(current: profit(in: curRange),
                          previous: profit(in: prevRange))
    }

    private var yearComparison: Comparison {
        guard let curStart = cal.date(from: DateComponents(year: taxYear, month: 4, day: 6)),
              let curEnd   = cal.date(from: DateComponents(year: taxYear + 1, month: 4, day: 6)),
              let prevStart = cal.date(from: DateComponents(year: taxYear - 1, month: 4, day: 6)) else {
            return Comparison(current: 0, previous: 0)
        }
        let curRange  = curStart...cal.date(byAdding: .second, value: -1, to: curEnd)!
        let prevRange = prevStart...cal.date(byAdding: .second, value: -1, to: curStart)!
        return Comparison(current: profit(in: curRange),
                          previous: profit(in: prevRange))
    }

    var body: some View {
        HStack(spacing: T.space4) {
            ComparisonCard(label: "vs last month", comparison: monthComparison)
            ComparisonCard(label: "vs last year",  comparison: yearComparison)
        }
    }

    fileprivate struct ComparisonCard: View {
        let label: String
        let comparison: Comparison

        private var arrow: String {
            comparison.delta >= 0 ? "arrow.up.right" : "arrow.down.right"
        }
        private var accent: Color {
            comparison.delta >= 0 ? C.sage : C.alert
        }
        private var pctText: String {
            guard let pct = comparison.pct else { return "n/a" }
            return String(format: "%+.0f%%", pct * 100)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: T.space2) {
                Text(label)
                    .font(.eyebrow)
                    .foregroundColor(C.mid)
                Text(fmt(comparison.current))
                    .font(.system(size: T.textLg, weight: .heavy))
                    .foregroundColor(C.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: arrow)
                        .font(.caption.weight(.bold))
                    Text(pctText)
                        .font(.system(size: T.textXs, weight: .bold, design: .monospaced))
                }
                .foregroundColor(accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(T.space4)
            .background(C.white)
            .overlay(
                RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                    .stroke(C.rule, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
        }
    }
}

// MARK: - Dashboard charts

/// Monthly profit (income − expenses) across the active tax year, shown
/// as a bar chart. Positive months render in sage, loss months in alert.
private struct MonthlyProfitChart: View {
    let entries: [Entry]
    let taxYear: Int
    let usdRate: Double

    private struct Bucket: Identifiable {
        let id = UUID()
        let month: Date    // first day of the month
        let income: Double
        let expense: Double
        var profit: Double { income - expense }
    }

    /// Build 12 buckets from 6 April (taxYear) to 5 April (taxYear+1).
    private var buckets: [Bucket] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        guard let start = cal.date(from: DateComponents(year: taxYear, month: 4, day: 6)) else { return [] }

        return (0..<12).compactMap { offset in
            guard let monthStart = cal.date(byAdding: .month, value: offset, to: start),
                  let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { return nil }
            let inMonth = entries.filter { $0.date >= monthStart && $0.date < monthEnd }
            let income  = inMonth.filter { $0.type == .income  }.reduce(0)  { $0 + $1.amountInGBP(usdRate: usdRate) }
            let expense = inMonth.filter { $0.type == .expense }.reduce(0)  { $0 + $1.amountInGBP(usdRate: usdRate) }
            return Bucket(month: monthStart, income: income, expense: expense)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.space2) {
            Text("Monthly profit")
                .font(.eyebrow)
                .foregroundColor(C.mid)
            Chart {
                ForEach(buckets) { b in
                    BarMark(
                        x: .value("Month", b.month, unit: .month),
                        y: .value("Profit", b.profit)
                    )
                    .foregroundStyle(b.profit >= 0 ? C.sage : C.alert)
                    .cornerRadius(4)
                }
            }
            .frame(height: 180)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { value in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                        .foregroundStyle(C.mid)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(C.rule)
                    AxisValueLabel().foregroundStyle(C.mid)
                }
            }
        }
        .padding(T.space5)
        .background(C.white)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(C.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

/// Donut chart of expenses by category for the active tax year.
private struct CategoryBreakdownChart: View {
    let entries: [Entry]
    let usdRate: Double

    private struct Slice: Identifiable {
        let id = UUID()
        let category: String
        let amount: Double
    }

    private var slices: [Slice] {
        let expenses = entries.filter { $0.type == .expense }
        let grouped = Dictionary(grouping: expenses, by: { $0.category.name })
        return grouped.map { (name, items) in
            let total = items.reduce(0) { $0 + $1.amountInGBP(usdRate: usdRate) }
            return Slice(category: name, amount: total)
        }
        .filter { $0.amount > 0 }
        .sorted { $0.amount > $1.amount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.space2) {
            Text("Expenses by category")
                .font(.eyebrow)
                .foregroundColor(C.mid)
            if slices.isEmpty {
                Text("No expenses yet.")
                    .font(.system(size: T.textSm))
                    .foregroundColor(C.mid)
                    .padding(.vertical, T.space4)
            } else {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Amount", slice.amount),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Category", slice.category))
                    .cornerRadius(4)
                }
                .frame(height: 200)
                .chartLegend(position: .bottom, alignment: .leading, spacing: T.space2)
            }
        }
        .padding(T.space5)
        .background(C.white)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(C.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

/// Quarterly view aligned to HMRC's MTD-IT obligations (mandatory from
/// April 2026 for £50k+ self-employed). Four quarters per UK tax year:
///   Q1: 6 Apr - 5 Jul
///   Q2: 6 Jul - 5 Oct
///   Q3: 6 Oct - 5 Jan
///   Q4: 6 Jan - 5 Apr
private struct MTDQuarterlyCard: View {
    let entries: [Entry]
    let taxYear: Int
    let usdRate: Double

    private struct Quarter: Identifiable {
        let id = UUID()
        let label: String
        let dateRange: String
        let income: Double
        let expenses: Double
        var profit: Double { income - expenses }
    }

    private var quarters: [Quarter] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let yearStart = cal.date(from: DateComponents(year: taxYear, month: 4, day: 6)) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"

        return (0..<4).compactMap { idx in
            guard let qStart = cal.date(byAdding: .month, value: idx * 3, to: yearStart),
                  let qEnd   = cal.date(byAdding: .month, value: (idx + 1) * 3, to: yearStart) else { return nil }
            let lastDay = cal.date(byAdding: .day, value: -1, to: qEnd) ?? qEnd
            let inQ = entries.filter { $0.date >= qStart && $0.date < qEnd }
            let income = inQ.filter { $0.type == .income }
                .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
            let expense = inQ.filter { $0.type == .expense && $0.resolvedAllowable }
                .reduce(0) { $0 + $1.totalAmountInGBP(usdRate: usdRate) }
            return Quarter(
                label: "Q\(idx + 1)",
                dateRange: "\(formatter.string(from: qStart)) – \(formatter.string(from: lastDay))",
                income: income,
                expenses: expense
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MTD-IT quarters")
                    .font(.system(size: T.textMd, weight: .bold))
                    .foregroundColor(C.ink)
                Text("Self-employment cumulative totals")
                    .font(.eyebrow)
                    .foregroundColor(C.sage)
            }
            VStack(spacing: T.space3) {
                ForEach(quarters) { q in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.label)
                                .font(.system(size: T.textSm, weight: .bold))
                                .foregroundColor(C.ink)
                            Text(q.dateRange)
                                .font(.system(size: T.textXs))
                                .foregroundColor(C.mid)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(fmt(q.profit))
                                .font(.system(size: T.textSm, weight: .bold, design: .monospaced))
                                .foregroundColor(q.profit >= 0 ? C.sage : C.alert)
                            Text("\(fmt(q.income)) − \(fmt(q.expenses))")
                                .font(.system(size: T.textXs, design: .monospaced))
                                .foregroundColor(C.mid)
                        }
                    }
                }
            }
            Text("Allowable expenses only. From 6 April 2026 HMRC requires self-employed people earning over £50,000 to submit quarterly via Making Tax Digital for Income Tax.")
                .font(.system(size: T.textXs))
                .foregroundColor(C.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(T.space5)
        .background(C.white)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(C.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

private struct TaxBandsReferenceCard: View {
    var body: some View {
        ReferenceCard(title: "UK Income Tax bands", subtitle: "2025/26 — England & NI") {
            ForEach(ukIncomeTaxBands2025_26) { band in
                ReferenceRow(
                    label: band.name,
                    range: bandRangeString(upTo: band.upTo, previousUpTo: previousUpTo(for: band)),
                    rate: "\(Int(band.rate * 100))%"
                )
            }
        }
    }

    private func previousUpTo(for band: TaxBand) -> Double? {
        guard let idx = ukIncomeTaxBands2025_26.firstIndex(where: { $0.name == band.name }),
              idx > 0 else { return nil }
        return ukIncomeTaxBands2025_26[idx - 1].upTo
    }
}

private struct NIBandsReferenceCard: View {
    var body: some View {
        ReferenceCard(title: "Class 4 NI bands", subtitle: "2025/26 — self-employed") {
            ForEach(ukClass4NIBands2025_26) { band in
                ReferenceRow(
                    label: band.name,
                    range: bandRangeString(upTo: band.upTo, previousUpTo: previousUpTo(for: band)),
                    rate: "\(Int(band.rate * 100))%"
                )
            }
        }
    }

    private func previousUpTo(for band: NIBand) -> Double? {
        guard let idx = ukClass4NIBands2025_26.firstIndex(where: { $0.name == band.name }),
              idx > 0 else { return nil }
        return ukClass4NIBands2025_26[idx - 1].upTo
    }
}

private func bandRangeString(upTo: Double?, previousUpTo: Double?) -> String {
    let from = previousUpTo.map { fmt($0) } ?? fmt(0)
    if let upTo {
        return "\(from) – \(fmt(upTo))"
    }
    return "Over \(from)"
}

private struct ReferenceCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: T.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: T.textMd, weight: .bold))
                    .foregroundColor(C.ink)
                Text(subtitle)
                    .font(.eyebrow)
                    .foregroundColor(C.sage)
            }
            VStack(spacing: T.space2) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(T.space5)
        .background(C.white)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(C.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

private struct ReferenceRow: View {
    let label: String
    let range: String
    let rate: String

    var body: some View {
        HStack(alignment: .top, spacing: T.space2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: T.textSm, weight: .semibold))
                    .foregroundColor(C.ink)
                Text(range)
                    .font(.system(size: T.textXs))
                    .foregroundColor(C.mid)
            }
            Spacer()
            Text(rate)
                .font(.system(size: T.textSm, weight: .bold, design: .monospaced))
                .foregroundColor(C.sage)
        }
    }
}

/// Quick-pick date window applied on top of the active tax year.
enum DateRangeFilter: String, CaseIterable, Identifiable {
    case all   = "All"
    case today = "Today"
    case week  = "This week"
    case month = "This month"

    var id: String { rawValue }

    func matches(_ date: Date, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        switch self {
        case .all:   return true
        case .today: return cal.isDateInToday(date)
        case .week:  return cal.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .month: return cal.isDate(date, equalTo: now, toGranularity: .month)
        }
    }
}

struct EntryListView: View {
    var entries: [Entry]
    var title: String
    var usdRate: Double
    var onEdit: (Entry) -> Void
    var onAddNew: () -> Void
    var onDuplicate: ((Entry) -> Void)? = nil
    var onDelete: ((Entry) -> Void)? = nil
    var onRefresh: (() async -> Void)? = nil

    @State private var searchText: String = ""
    @State private var selectedCategoryFilter: String? = nil
    @State private var dateRange: DateRangeFilter = .all

    /// Categories present in the current set, sorted by frequency desc then name.
    private var visibleCategories: [String] {
        let counts = Dictionary(grouping: entries, by: { $0.category.name })
            .mapValues(\.count)
        return counts.keys.sorted { (a, b) in
            let (ca, cb) = (counts[a] ?? 0, counts[b] ?? 0)
            return ca == cb ? a < b : ca > cb
        }
    }

    /// Entries after applying date range + search + category chip.
    private var filteredEntries: [Entry] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { e in
            if !dateRange.matches(e.date) { return false }
            if let cat = selectedCategoryFilter, e.category.name != cat { return false }
            if !q.isEmpty {
                let hay = "\(e.description) \(e.category.name) \(e.vendor ?? "")".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    private var subtitle: String {
        let total = entries.count
        let shown = filteredEntries.count
        if shown == total {
            return "\(total) \(total == 1 ? "entry" : "entries")"
        }
        return "\(shown) of \(total) \(total == 1 ? "entry" : "entries")"
    }

    private var hasActiveFilter: Bool {
        !searchText.isEmpty || selectedCategoryFilter != nil || dateRange != .all
    }

    var body: some View {
        List {
            Section {
                TallyPageHeader(title: title, subtitle: subtitle)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                DateRangeChips(selected: $dateRange)
                    .listRowInsets(EdgeInsets(top: 0, leading: T.space6,
                                              bottom: T.space2, trailing: T.space6))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if visibleCategories.count > 1 {
                Section {
                    CategoryFilterChips(
                        categories: visibleCategories,
                        selected: $selectedCategoryFilter
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: T.space6,
                                              bottom: T.space2, trailing: T.space6))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            Section {
                if filteredEntries.isEmpty {
                    VStack(spacing: T.space2) {
                        Text(entries.isEmpty
                             ? "No \(title.lowercased()) yet"
                             : "No matching \(title.lowercased())")
                            .font(.bodyText)
                            .foregroundColor(C.mid)
                        if hasActiveFilter {
                            Button("Clear filters") {
                                searchText = ""
                                selectedCategoryFilter = nil
                                dateRange = .all
                            }
                            .font(.system(size: T.textSm, weight: .semibold))
                            .foregroundColor(C.sage)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, T.space6)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredEntries) { entry in
                        EntryRow(entry: entry, usdRate: usdRate)
                            .contentShape(Rectangle())
                            .onTapGesture { onEdit(entry) }
                            .listRowInsets(EdgeInsets(top: 6, leading: T.space6,
                                                      bottom: 6, trailing: T.space6))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let onDuplicate {
                                    Button {
                                        onDuplicate(entry)
                                    } label: {
                                        Label("Duplicate", systemImage: "plus.square.on.square")
                                    }
                                    .tint(C.sage)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let onDelete {
                                    Button(role: .destructive) {
                                        onDelete(entry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }

            Section {
                Button { onAddNew() } label: {
                    Label("Add \(title.dropLast())", systemImage: "plus.circle.fill")
                }
                .buttonStyle(TallyGhostButtonStyle())
                .listRowInsets(EdgeInsets(top: T.space4, leading: T.space6,
                                          bottom: T.space8, trailing: T.space6))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(C.paper)
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search \(title.lowercased())")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .refreshable {
            if let onRefresh { await onRefresh() }
        }
    }
}

private struct CategoryFilterChips: View {
    let categories: [String]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: T.space2) {
                Chip(label: "All", isOn: selected == nil) {
                    selected = nil
                }
                ForEach(categories, id: \.self) { name in
                    Chip(label: name, isOn: selected == name) {
                        selected = (selected == name) ? nil : name
                    }
                }
            }
            .padding(.vertical, T.space1)
        }
    }

    private struct Chip: View {
        let label: String
        let isOn: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: T.textXs, weight: .bold))
                    .foregroundColor(isOn ? .white : C.sage)
                    .padding(.horizontal, T.space3)
                    .padding(.vertical, 6)
                    .background(isOn ? C.sage : C.sagePale)
                    .overlay(
                        Capsule().stroke(isOn ? C.sage : C.mint, lineWidth: 1)
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Today / This week / This month / All quick-pick chips. Visual style
/// matches CategoryFilterChips.
private struct DateRangeChips: View {
    @Binding var selected: DateRangeFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: T.space2) {
                ForEach(DateRangeFilter.allCases) { range in
                    Button {
                        selected = range
                    } label: {
                        Text(range.rawValue)
                            .font(.system(size: T.textXs, weight: .bold))
                            .foregroundColor(selected == range ? .white : C.sage)
                            .padding(.horizontal, T.space3)
                            .padding(.vertical, 6)
                            .background(selected == range ? C.sage : C.sagePale)
                            .overlay(
                                Capsule().stroke(selected == range ? C.sage : C.mint, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, T.space1)
        }
    }
}

private struct EntryRow: View {
    let entry: Entry
    let usdRate: Double

    private var amountColor: Color {
        entry.type == .expense ? C.alert : C.sageLight
    }
    private var sign: String {
        entry.type == .expense ? "−" : "+"
    }

    /// Combined recurrence + duration label so the meta row only carries one pill.
    private var termLabel: String? {
        let rec = entry.recurrence.flatMap { $0 == .none ? nil : $0 }
        switch (rec, entry.duration) {
        case let (r?, d?): return "\(r.label) · \(d.label)"
        case let (r?, nil): return r.label
        case let (nil, d?): return d.label
        case (nil, nil): return nil
        }
    }

    private var supplementary: (text: String, color: Color)? {
        if entry.hasCommitment {
            return ("Total \(fmt(entry.totalAmountInGBP(usdRate: usdRate)))", C.sage)
        }
        if entry.resolvedCurrency == .usd {
            return ("≈ \(fmt(entry.amountInGBP(usdRate: usdRate)))", C.usd)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: T.space3) {
            ZStack {
                RoundedRectangle(cornerRadius: T.radiusSm)
                    .fill(entry.category.color.opacity(0.18))
                Text(String(entry.category.name.prefix(1)))
                    .font(.system(size: T.textMd, weight: .bold))
                    .foregroundColor(entry.category.color)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                // Top line: description ⇄ amount (single line, both truncate gracefully)
                HStack(alignment: .firstTextBaseline, spacing: T.space2) {
                    Text(entry.vendor
                         ?? (entry.description.isEmpty ? entry.category.name : entry.description))
                        .font(.system(size: T.textSm, weight: .semibold))
                        .foregroundColor(C.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: T.space2)
                    Text("\(sign)\(fmt(entry.amount, currency: entry.resolvedCurrency))")
                        .font(.system(size: T.textMd, weight: .bold))
                        .foregroundColor(amountColor)
                        .lineLimit(1)
                        .fixedSize()
                }

                // Bottom line: date · term pill · paperclip ⇄ total / GBP equivalent
                HStack(alignment: .center, spacing: T.space2) {
                    Text(shortDate(entry.date))
                        .font(.system(size: T.textXs))
                        .foregroundColor(C.mid)
                        .lineLimit(1)
                    if let term = termLabel {
                        TallyPill(label: term, style: .sage)
                            .layoutPriority(0)
                    }
                    if let attachments = entry.attachments, !attachments.isEmpty {
                        Label("\(attachments.count)", systemImage: "paperclip")
                            .font(.system(size: T.textXs, weight: .semibold))
                            .foregroundColor(C.mid)
                            .labelStyle(.titleAndIcon)
                    }
                    if entry.parentEntryId != nil {
                        Label("Auto", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: T.textXs, weight: .semibold))
                            .foregroundColor(C.sage)
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer(minLength: T.space2)
                    if let supp = supplementary {
                        Text(supp.text)
                            .font(.system(size: T.textXs, weight: .semibold))
                            .foregroundColor(supp.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(C.white)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(C.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

struct TallyPill: View {
    enum Style { case sage, amber, expense }
    let label: String
    var style: Style = .sage

    private var fg: Color {
        switch style { case .sage: C.sage; case .amber: C.amber; case .expense: C.alert }
    }
    private var bg: Color {
        switch style {
        case .sage: C.sagePale
        case .amber: C.amber.opacity(0.1)
        case .expense: C.alert.opacity(0.1)
        }
    }
    private var border: Color {
        switch style {
        case .sage: C.mint
        case .amber: C.amber.opacity(0.25)
        case .expense: C.alert.opacity(0.2)
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: T.textXs, weight: .bold))
            .foregroundColor(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(bg)
            .overlay(Capsule().stroke(border, lineWidth: 1))
            .clipShape(Capsule())
    }
}

struct SummaryView: View {
    var entries: [Entry]
    var taxYear: Int
    var taxCode: String
    var usdRate: Double

    private var income: Double {
        entries.filter { $0.type == .income }
            .map { $0.totalAmountInGBP(usdRate: usdRate) }
            .reduce(0, +)
    }
    /// All expenses, allowable or not.
    private var expenses: Double {
        entries.filter { $0.type == .expense }
            .map { $0.totalAmountInGBP(usdRate: usdRate) }
            .reduce(0, +)
    }
    /// Expenses that count toward taxable profit (`isAllowable` true / nil).
    private var allowableExpenses: Double {
        entries.filter { $0.type == .expense && $0.resolvedAllowable }
            .map { $0.totalAmountInGBP(usdRate: usdRate) }
            .reduce(0, +)
    }
    private var disallowableExpenses: Double { expenses - allowableExpenses }
    /// Profit for tax purposes — only allowable expenses are deducted.
    private var profit: Double { income - allowableExpenses }
    private var personalAllowance: Double {
        Double(parseTaxCode(taxCode) ?? 12570)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TallyPageHeader(title: "Tax summary",
                                subtitle: "Year \(String(taxYear))/\(String(taxYear + 1)) — code \(taxCode)")

                VStack(spacing: T.space4) {
                    SummaryCard(label: "Taxable profit",
                                value: fmt(profit),
                                accent: C.sage,
                                style: .sage)

                    HStack(spacing: T.space4) {
                        SummaryCard(label: "Income",
                                    value: fmt(income),
                                    accent: C.sageLight,
                                    style: .plain)
                        SummaryCard(label: "Expenses",
                                    value: fmt(expenses),
                                    accent: C.alert,
                                    style: .plain)
                    }

                    if disallowableExpenses > 0 {
                        HStack(spacing: T.space2) {
                            VATBreakdownChip(label: "Allowable",    amount: allowableExpenses,    color: C.sage)
                            VATBreakdownChip(label: "Disallowable", amount: disallowableExpenses, color: C.mid)
                        }
                        .padding(.horizontal, T.space2)
                    }

                    SummaryCard(label: "Personal allowance",
                                value: fmt(personalAllowance),
                                accent: C.amber,
                                style: .amber)

                    EstimatesGroup(entries: entries,
                                   profit: profit,
                                   expenses: expenses,
                                   allowableExpenses: allowableExpenses,
                                   personalAllowance: personalAllowance,
                                   usdRate: usdRate)

                    MTDQuarterlyCard(entries: entries, taxYear: taxYear, usdRate: usdRate)

                    TaxBandsReferenceCard()
                    NIBandsReferenceCard()

                    Text("USD rate: \(usdRate, specifier: "%.2f")")
                        .font(.system(size: T.textXs))
                        .foregroundColor(C.mid)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, T.space2)
                }
                .padding(.horizontal, T.space6)
                .padding(.bottom, T.space8)
            }
        }
        .background(C.paper)
    }
}

struct EntryModalView: View {
    @Binding var entry: Entry?
    var usdRate: Double
    var customCategoryNames: [String] = []
    var onSave: (Entry) -> Void
    var onCancel: () -> Void
    var onAddCustomCategory: ((String) -> Void)? = nil

    @State private var showNewCategoryPrompt = false
    @State private var newCategoryDraft: String = ""

    @State private var descriptionText: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = Date()
    @State private var selectedType: Entry.EntryType = .expense
    @State private var recurrence: Recurrence = .none
    @State private var duration: Duration? = nil
    @State private var currency: Currency = .gbp
    @State private var attachments: [PDFAttachment] = []
    @State private var showFileImporter = false
    @State private var notesText: String = ""
    @State private var vatRate: VATRate = .unspecified
    @State private var vendorText: String = ""
    @State private var isAllowable: Bool = true
    @State private var incomeType: IncomeType = .freelance

    // Built-in expense categories. Identified by name (stable) — the UUID is just
    // for downstream Codable storage on Entry. SwiftUI Pickers select by name.
    private let builtInCategoryDefs: [(name: String, colorName: String)] = [
        ("General",          "primary"),
        ("Food",             "orange"),
        ("Transport",        "blue"),
        ("Salary",           "green"),
        ("Tax",              "red"),
        ("Domain names",     "sage"),
        ("Web hosting",      "sageLight"),
        ("SSL Certificates", "amber"),
        ("GenAI",            "mint")
    ]

    /// All categories presented in the picker. Built-ins first, then user-added.
    private var categories: [Category] {
        let builtIns = builtInCategoryDefs.map {
            Category(id: UUID(), name: $0.name, colorName: $0.colorName)
        }
        let custom = customCategoryNames.map {
            Category(id: UUID(), name: $0, colorName: "sage")
        }
        return builtIns + custom
    }

    /// Picker selection keyed by `name`. Stable across renders — the underlying
    /// Category's UUID changes on each render but the name does not, so the
    /// picker selection always matches a current tag.
    @State private var selectedCategoryName: String = ""

    /// Accepts a plain decimal (`12.99`) or a simple arithmetic expression
    /// (`12.99 + 5.50`, `200/3`, `(1+2)*3.5`). Powered by NSExpression so the
    /// safe operators only — no key paths, no function calls.
    private var amountAsDouble: Double? {
        evaluateAmountExpression(amountText)
    }
    private var gbpEquivalent: Double? {
        guard let amount = amountAsDouble, currency == .usd, usdRate > 0 else { return nil }
        return amount / usdRate
    }

    /// Live preview of the commitment total + mismatch state, based on the current form inputs.
    private var previewCommitment: (shouldShow: Bool, total: Double, mismatched: Bool) {
        guard let amount = amountAsDouble,
              recurrence != .none,
              recurrence.timesPerYear > 0,
              let dur = duration else {
            return (false, 0, false)
        }
        let multiplier = recurrence.timesPerYear * dur.inYears
        let mismatched = (recurrence.yearsPerCycle ?? 0) > dur.inYears
        return (true, amount * multiplier, mismatched)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Details")) {
                    TextField(selectedType == .income ? "Payer (e.g. Acme Ltd)" : "Vendor (e.g. Cloudflare)",
                              text: $vendorText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    TextField("Description", text: $descriptionText)
                    HStack {
                        Text(currency.symbol)
                            .foregroundColor(C.mid)
                        TextField("Amount or expression (e.g. 12.99 + 5)", text: $amountText)
                            .keyboardType(.asciiCapableNumberPad)
                            .autocorrectionDisabled()
                    }
                    if let resolved = amountAsDouble,
                       amountText.trimmingCharacters(in: .whitespaces).count > 0,
                       Double(amountText) == nil {
                        HStack {
                            Text("= ")
                                .foregroundColor(C.mid)
                            Text(fmt(resolved, currency: currency))
                                .font(.system(.body, weight: .semibold))
                                .foregroundColor(C.sage)
                            Spacer()
                        }
                    }
                    Picker("Currency", selection: $currency) {
                        ForEach(Currency.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    if let gbp = gbpEquivalent {
                        HStack {
                            Text("≈ in GBP")
                                .foregroundColor(C.mid)
                            Spacer()
                            Text(fmt(gbp))
                                .foregroundColor(C.usd)
                                .font(.system(.body, weight: .semibold))
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Type", selection: $selectedType) {
                        Text("Expense").tag(Entry.EntryType.expense)
                        Text("Income").tag(Entry.EntryType.income)
                        Text("Tax").tag(Entry.EntryType.tax)
                    }
                    Picker("Category", selection: $selectedCategoryName) {
                        ForEach(categories) { category in
                            Text(category.name).tag(category.name)
                        }
                    }
                    if onAddCustomCategory != nil {
                        Button {
                            newCategoryDraft = ""
                            showNewCategoryPrompt = true
                        } label: {
                            Label("New category…", systemImage: "plus.circle")
                                .foregroundColor(C.sage)
                        }
                    }
                    Picker("Recurrence", selection: $recurrence) {
                        ForEach(Recurrence.allCases, id: \.self) { rec in
                            Text(rec.label).tag(rec)
                        }
                    }
                    Picker("Duration", selection: $duration) {
                        Text("None").tag(Duration?.none)
                        ForEach(Duration.allCases) { d in
                            Text(d.label).tag(Duration?.some(d))
                        }
                    }
                    Picker("VAT", selection: $vatRate) {
                        ForEach(VATRate.allCases) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    if selectedType == .expense {
                        Toggle("Allowable for tax", isOn: $isAllowable)
                    }
                    if selectedType == .income {
                        Picker("Income type", selection: $incomeType) {
                            ForEach(IncomeType.allCases) { t in
                                Text(t.label).tag(t)
                            }
                        }
                    }
                    if previewCommitment.shouldShow {
                        HStack {
                            Text("Total over term")
                                .foregroundColor(C.mid)
                            Spacer()
                            Text(fmt(previewCommitment.total, currency: currency))
                                .font(.system(.body, weight: .semibold))
                                .foregroundColor(C.sage)
                        }
                    }
                    if previewCommitment.mismatched {
                        Label("Duration is shorter than one \(recurrence.label.lowercased()) cycle — check your figures.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(C.amber)
                    }
                }

                Section {
                    TextField("Anything else — receipts, context, reminders", text: $notesText, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Notes")
                }

                Section {
                    ForEach(attachments) { attachment in
                        HStack(spacing: T.space2) {
                            Image(systemName: "doc.fill")
                                .foregroundColor(C.alert)
                            VStack(alignment: .leading) {
                                Text(attachment.displayName)
                                    .font(.system(size: T.textSm, weight: .semibold))
                                    .lineLimit(1)
                                Text(shortDate(attachment.dateAdded))
                                    .font(.caption)
                                    .foregroundColor(C.mid)
                            }
                            Spacer()
                            ShareLink(item: AttachmentStore.shared.url(for: attachment)) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            AttachmentStore.shared.delete(attachments[index])
                        }
                        attachments.remove(atOffsets: offsets)
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Add PDF", systemImage: "paperclip")
                    }
                } header: {
                    Text("Attachments")
                } footer: {
                    Text("Attach receipts, invoices, or contracts as PDF.")
                }
            }
            .navigationTitle(entry == nil ? "New Entry" : "Edit Entry")
            .navigationBarItems(
                leading: Button("Cancel") {
                    onCancel()
                },
                trailing: Button("Save") {
                    guard let amount = amountAsDouble,
                          let selectedCategory = categories.first(where: { $0.name == selectedCategoryName })
                    else { return }
                    let newEntry = Entry(
                        id: entry?.id ?? UUID(),
                        date: date,
                        description: descriptionText,
                        amount: amount,
                        type: selectedType,
                        category: selectedCategory,
                        recurrence: recurrence == .none ? nil : recurrence,
                        duration: duration,
                        attachments: attachments.isEmpty ? nil : attachments,
                        currency: currency,
                        // Preserve the auto-gen lineage when editing an existing
                        // entry so editing a child doesn't sever its link to
                        // the template, and editing a template keeps its
                        // last-generated marker so old cycles aren't re-spawned.
                        parentEntryId: entry?.parentEntryId,
                        lastGeneratedAt: entry?.lastGeneratedAt,
                        notes: notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notesText,
                        vatRate: vatRate == .unspecified ? nil : vatRate,
                        vendor: vendorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : vendorText.trimmingCharacters(in: .whitespacesAndNewlines),
                        isAllowable: selectedType == .expense ? isAllowable : nil,
                        incomeType: selectedType == .income ? incomeType : nil
                    )
                    onSave(newEntry)
                }
                .disabled(descriptionText.isEmpty || amountAsDouble == nil || selectedCategoryName.isEmpty)
            )
            .alert("New category", isPresented: $showNewCategoryPrompt) {
                TextField("Name", text: $newCategoryDraft)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    let trimmed = newCategoryDraft.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onAddCustomCategory?(trimmed)
                    selectedCategoryName = trimmed
                    Haptics.success()
                }
            } message: {
                Text("Added to your custom categories. Appears in the picker straight away.")
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        if let attachment = AttachmentStore.shared.importPDF(from: url) {
                            attachments.append(attachment)
                        }
                    }
                case .failure:
                    break
                }
            }
            .onAppear {
                if let entry = entry {
                    descriptionText = entry.description
                    amountText = String(entry.amount)
                    date = entry.date
                    selectedType = entry.type
                    selectedCategoryName = entry.category.name
                    recurrence = entry.recurrence ?? .none
                    duration = entry.duration
                    currency = entry.resolvedCurrency
                    attachments = entry.attachments ?? []
                    notesText = entry.notes ?? ""
                    vatRate = entry.vatRate ?? .unspecified
                    vendorText = entry.vendor ?? ""
                    isAllowable = entry.resolvedAllowable
                    incomeType = entry.resolvedIncomeType
                } else {
                    selectedCategoryName = categories.first?.name ?? ""
                    recurrence = .none
                    duration = nil
                    currency = .gbp
                    attachments = []
                    notesText = ""
                    vatRate = .unspecified
                    vendorText = ""
                    isAllowable = true
                    incomeType = .freelance
                }
            }
        }
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .padding()
            .background(C.primary.opacity(0.9))
            .foregroundColor(.white)
            .cornerRadius(8)
            .padding(.bottom, 50)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeInOut, value: message)
    }
}

// MARK: - Auth Flow Views

struct AuthFlowView: View {
    @ObservedObject var loginManager: LoginManager

    var body: some View {
        switch loginManager.step {
        case .signUp:
            SignUpView(loginManager: loginManager)
        case .verifyEmail:
            VerifyEmailView(loginManager: loginManager)
        case .signIn:
            SignInView(loginManager: loginManager)
        case .authenticated:
            EmptyView()
        }
    }
}

struct SignUpView: View {
    @ObservedObject var loginManager: LoginManager
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @FocusState private var focused: Field?
    private enum Field { case email, password, confirm }

    var body: some View {
        ScrollView {
            VStack(spacing: T.space6) {
                VStack(spacing: T.space4) {
                    TallyWordmark()
                        .padding(.top, T.space12)
                    Text("Tax made human.")
                        .font(.strapline)
                        .foregroundColor(C.sage)
                }

                VStack(alignment: .leading, spacing: T.space2) {
                    Text("Create your account")
                        .font(.displayLg)
                        .foregroundColor(C.ink)
                    Text("A few details to get your tally going.")
                        .font(.bodyText)
                        .foregroundColor(C.mid)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, T.space8)
                .padding(.top, T.space6)

                VStack(spacing: T.space4) {
                    LabeledField(label: "Email") {
                        TextField("you@domain.com", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($focused, equals: .email)
                            .tallyInput(focused: focused == .email)
                    }
                    LabeledField(label: "Password") {
                        SecureField("At least 8 characters", text: $password)
                            .textContentType(.newPassword)
                            .focused($focused, equals: .password)
                            .tallyInput(focused: focused == .password)
                    }
                    LabeledField(label: "Confirm password") {
                        SecureField("Re-enter password", text: $confirmPassword)
                            .textContentType(.newPassword)
                            .focused($focused, equals: .confirm)
                            .tallyInput(focused: focused == .confirm)
                    }
                }
                .padding(.horizontal, T.space8)

                if let error = loginManager.formError {
                    FormErrorView(message: error)
                }

                Button("Create Account") {
                    loginManager.signUp(email: email, password: password, confirmPassword: confirmPassword)
                }
                .buttonStyle(TallyPrimaryButtonStyle())
                .padding(.horizontal, T.space8)

                Button("Already have an account? Sign In") {
                    loginManager.goToSignIn()
                }
                .font(.system(size: T.textSm, weight: .semibold))
                .foregroundColor(C.sage)

                Spacer(minLength: T.space8)
            }
        }
        .background(C.paper.ignoresSafeArea())
    }
}

struct VerifyEmailView: View {
    @ObservedObject var loginManager: LoginManager
    @State private var code: String = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: T.space6) {
                TallyWordmark()
                    .padding(.top, T.space12)

                VStack(alignment: .leading, spacing: T.space2) {
                    Text("Verify your email")
                        .font(.displayLg)
                        .foregroundColor(C.ink)
                    // Markdown bold for the email; SwiftUI's Text + Text
                    // concatenation is deprecated in iOS 26.
                    Text("Enter the 6-digit code we sent to **\(loginManager.storedEmail)**")
                        .font(.bodyText)
                        .foregroundColor(C.mid)
                        .tint(C.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, T.space8)
                .padding(.top, T.space4)

                if let pending = loginManager.pendingVerificationCode {
                    VStack(spacing: T.space2) {
                        Text("Demo code — no email service wired up yet")
                            .font(.eyebrow)
                            .foregroundColor(Color(hex: "#7A4E0E"))
                        // Fixed dark colour so the code stays readable on the
                        // light amber surface in both light and dark mode.
                        Text(pending)
                            .font(.system(size: T.text2xl, weight: .heavy, design: .monospaced))
                            .tracking(6)
                            .foregroundColor(Color(hex: "#1A1C18"))
                            .padding(.horizontal, T.space4)
                            .padding(.vertical, T.space2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(T.space4)
                    .background(C.amberPale)
                    .overlay(
                        RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                            .stroke(C.amber.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
                    .padding(.horizontal, T.space8)
                }

                LabeledField(label: "Verification code") {
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .focused($codeFocused)
                        .font(.system(size: T.textLg, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .tallyInput(focused: codeFocused)
                }
                .padding(.horizontal, T.space8)

                if let error = loginManager.formError {
                    FormErrorView(message: error)
                }

                Button("Verify Email") {
                    loginManager.verifyEmail(code: code)
                }
                .buttonStyle(TallyPrimaryButtonStyle())
                .padding(.horizontal, T.space8)

                Button("Resend Code") {
                    loginManager.issueVerificationCode()
                }
                .buttonStyle(TallyGhostButtonStyle())
                .padding(.horizontal, T.space8)

                Button("Start over") {
                    loginManager.resetAccount()
                }
                .font(.system(size: T.textSm, weight: .semibold))
                .foregroundColor(C.mid)

                Spacer(minLength: T.space8)
            }
        }
        .background(C.paper.ignoresSafeArea())
    }
}

struct SignInView: View {
    @ObservedObject var loginManager: LoginManager
    @State private var email: String = ""
    @State private var password: String = ""
    @FocusState private var focused: Field?
    private enum Field { case email, password }

    private var biometricLabel: String {
        switch loginManager.availableBiometryType {
        case .faceID: return "Sign in with Face ID"
        case .touchID: return "Sign in with Touch ID"
        case .opticID: return "Sign in with Optic ID"
        default: return "Sign in with Biometrics"
        }
    }

    private var biometricIcon: String {
        switch loginManager.availableBiometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.shield"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: T.space6) {
                VStack(spacing: T.space4) {
                    TallyWordmark()
                        .padding(.top, T.space12)
                    Text("Tax made human.")
                        .font(.strapline)
                        .foregroundColor(C.sage)
                }

                VStack(alignment: .leading, spacing: T.space2) {
                    Text("Welcome back")
                        .font(.displayLg)
                        .foregroundColor(C.ink)
                    Text("Sign in to keep your tally up to date.")
                        .font(.bodyText)
                        .foregroundColor(C.mid)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, T.space8)
                .padding(.top, T.space6)

                VStack(spacing: T.space4) {
                    LabeledField(label: "Email") {
                        TextField("you@domain.com", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($focused, equals: .email)
                            .tallyInput(focused: focused == .email)
                    }
                    LabeledField(label: "Password") {
                        SecureField("Your password", text: $password)
                            .textContentType(.password)
                            .focused($focused, equals: .password)
                            .tallyInput(focused: focused == .password)
                    }
                }
                .padding(.horizontal, T.space8)

                if let error = loginManager.formError {
                    FormErrorView(message: error)
                }

                Button("Sign In") {
                    loginManager.signIn(email: email, password: password)
                }
                .buttonStyle(TallyPrimaryButtonStyle())
                .padding(.horizontal, T.space8)

                if loginManager.canUseBiometrics {
                    Button {
                        loginManager.loginWithBiometrics()
                    } label: {
                        HStack(spacing: T.space2) {
                            Image(systemName: biometricIcon)
                            Text(biometricLabel)
                        }
                    }
                    .buttonStyle(TallyGhostButtonStyle())
                    .padding(.horizontal, T.space8)
                }

                if let bioError = loginManager.biometricError {
                    FormErrorView(message: bioError)
                }

                Button("New here? Create an account") {
                    loginManager.goToSignUp()
                }
                .font(.system(size: T.textSm, weight: .semibold))
                .foregroundColor(C.sage)

                Spacer(minLength: T.space8)
            }
            .onAppear {
                if email.isEmpty { email = loginManager.storedEmail }
            }
        }
        .background(C.paper.ignoresSafeArea())
    }
}

// MARK: - Auth Form Helpers

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: T.space2) {
            Text(label)
                .font(.system(size: T.textXs, weight: .bold))
                .tracking(1.2)
                .foregroundColor(C.mid)
                .textCase(.uppercase)
            content()
        }
    }
}

private struct FormErrorView: View {
    let message: String
    var body: some View {
        HStack(spacing: T.space2) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message)
                .font(.system(size: T.textSm, weight: .semibold))
        }
        .foregroundColor(C.alert)
        .padding(.horizontal, T.space4)
        .padding(.vertical, T.space2)
        .background(C.alert.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: T.radiusMd, style: .continuous))
        .padding(.horizontal, T.space8)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Binding var profileData: Data
    @Binding var entriesData: Data
    @Binding var appearanceMode: AppearanceMode
    @Binding var taxCode: String
    @Binding var customCategoriesData: Data
    @Binding var usdRate: Double
    @Binding var usdRateUpdatedAt: Double
    var entries: [Entry]
    var taxYear: Int
    var onLoadSampleData: () -> Void
    @ObservedObject var loginManager: LoginManager
    @Environment(\.dismiss) private var dismiss

    @State private var profile = UserProfile()
    @State private var dobDate = Date()
    @State private var hasDob = false
    @State private var showDeleteConfirm = false
    @State private var customCategories: [String] = []
    @State private var newCategoryName: String = ""
    @State private var isRefreshingRate = false
    @State private var showSampleConfirm = false
    @AppStorage("biometricEnabled") private var biometricEnabled: Bool = true
    @AppStorage("hmrcDeadlineReminders") private var hmrcRemindersEnabled: Bool = false

    private var biometricToggleLabel: String {
        switch loginManager.availableBiometryType {
        case .faceID:  "Enable Face ID"
        case .touchID: "Enable Touch ID"
        case .opticID: "Enable Optic ID"
        default:       "Enable biometric sign-in"
        }
    }

    private var biometricToggleIcon: String {
        switch loginManager.availableBiometryType {
        case .faceID:  "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        default:       "lock.shield"
        }
    }

    private var rateLastUpdatedLabel: String {
        guard usdRateUpdatedAt > 0 else { return "never" }
        let date = Date(timeIntervalSince1970: usdRateUpdatedAt)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var exportURL: URL? {
        let csv = EntryCSV.makeCSV(entries: entries, usdRate: usdRate)
        let stamp = DateFormatter.tallyExportStamp.string(from: Date())
        let filename = "tally-entries-\(stamp).csv"
        return try? EntryCSV.writeToTemp(csv: csv, filename: filename)
    }

    private var pdfURL: URL? {
        var profile = UserProfile()
        if !profileData.isEmpty,
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: profileData) {
            profile = decoded
        }
        return TaxYearPDF.build(taxYear: taxYear,
                                profile: profile,
                                taxCode: taxCode,
                                entries: entries,
                                usdRate: usdRate)
    }

    private var personalAllowance: Int? {
        parseTaxCode(taxCode)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Full name", text: $profile.name)
                        .textContentType(.name)
                    TextField("NI number (e.g. QQ123456C)", text: $profile.niNumber)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                    VStack(alignment: .leading, spacing: T.space2) {
                        Text("Address")
                            .font(.caption)
                            .foregroundColor(C.mid)
                        TextEditor(text: $profile.address)
                            .frame(minHeight: 80)
                    }
                    Toggle("Set date of birth", isOn: $hasDob)
                    if hasDob {
                        DatePicker("Date of birth",
                                   selection: $dobDate,
                                   in: ...Date(),
                                   displayedComponents: .date)
                    }
                    HStack {
                        TextField("Tax code (e.g. 1257L)", text: $taxCode)
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                        Menu {
                            ForEach(commonTaxCodes) { preset in
                                Button {
                                    taxCode = preset.code
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(preset.code)
                                        Text(preset.description)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        .accessibilityLabel("Common tax codes")

                        if let allowance = personalAllowance {
                            Text(fmt(Double(allowance)))
                                .font(.system(.body, weight: .semibold))
                                .foregroundColor(C.sage)
                        } else {
                            Text("invalid")
                                .font(.caption)
                                .foregroundColor(C.alert)
                        }
                    }
                } header: {
                    Text("Your details")
                } footer: {
                    Text("Tax code drives your personal allowance on the Tax summary. Stored locally on this device.")
                }

                Section {
                    ForEach(customCategories, id: \.self) { name in
                        Text(name)
                    }
                    .onDelete { offsets in
                        customCategories.remove(atOffsets: offsets)
                    }
                    HStack {
                        TextField("Add a custom category", text: $newCategoryName)
                        Button {
                            addCategory()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(C.sage)
                        }
                        .disabled(newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Custom categories")
                } footer: {
                    Text("Added categories appear in the entry form picker alongside the built-in ones.")
                }

                Section {
                    Toggle("HMRC deadline reminders", isOn: $hmrcRemindersEnabled)
                        .onChange(of: hmrcRemindersEnabled) { _, newValue in
                            handleHMRCToggle(newValue)
                        }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("Notifies 30 days, 7 days, and on the morning of each self-assessment deadline: 31 January (balancing payment) and 31 July (second payment on account).")
                }

                Section {
                    Picker("Theme", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                }

                Section {
                    if let url = exportURL {
                        ShareLink(item: url) {
                            Label("Export entries as CSV", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Label("Export entries as CSV", systemImage: "square.and.arrow.up")
                            .foregroundColor(C.mid)
                    }

                    if let url = pdfURL {
                        ShareLink(item: url, preview: SharePreview("Tally tax summary \(taxYear)/\(taxYear + 1)")) {
                            Label("Export tax-year PDF", systemImage: "doc.richtext")
                        }
                    } else {
                        Label("Export tax-year PDF", systemImage: "doc.richtext")
                            .foregroundColor(C.mid)
                    }

                    Button {
                        if entries.isEmpty {
                            onLoadSampleData()
                            dismiss()
                        } else {
                            showSampleConfirm = true
                        }
                    } label: {
                        Label("Load sample tax year", systemImage: "wand.and.stars")
                    }

                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("USD rate")
                                Text("Updated \(rateLastUpdatedLabel)")
                                    .font(.caption)
                                    .foregroundColor(C.mid)
                            }
                        } icon: {
                            Image(systemName: "sterlingsign.arrow.circlepath")
                        }
                        Spacer()
                        Text(String(format: "%.4f", usdRate))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(C.sage)
                        Button {
                            refreshRate()
                        } label: {
                            if isRefreshingRate {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isRefreshingRate)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export every entry as CSV — date, type, category, amount, currency, GBP equivalent, recurrence/duration, attachment count. The USD rate (USD per 1 GBP) drives currency conversion; it auto-refreshes every 12 hours and can be refreshed manually from here.")
                }

                Section {
                    if loginManager.availableBiometryType != .none {
                        Toggle(isOn: $biometricEnabled) {
                            Label(biometricToggleLabel, systemImage: biometricToggleIcon)
                        }
                    }
                    Button {
                        signOut()
                    } label: {
                        Label("Sign out", systemImage: "lock.fill")
                    }
                } header: {
                    Text("Session")
                } footer: {
                    if loginManager.availableBiometryType == .none {
                        Text("Locks the app. Your data stays put — sign in again with your password.")
                    } else {
                        Text("Locks the app and (when biometrics are enabled) shows the \(biometricToggleLabel.replacingOccurrences(of: "Enable ", with: "")) button on the Sign In screen.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete all data", systemImage: "trash")
                    }
                } header: {
                    Text("Danger zone")
                } footer: {
                    Text("Permanently removes your profile, entries, attachments, and account.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
            .confirmationDialog(
                "Delete all data?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) { deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove your profile, entries, attachments, and account.")
            }
            .confirmationDialog(
                "Load sample data?",
                isPresented: $showSampleConfirm,
                titleVisibility: .visible
            ) {
                Button("Add to existing entries") {
                    onLoadSampleData()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Adds ~30 representative entries across the active tax year, alongside any you already have.")
            }
        }
    }

    private func load() {
        if !profileData.isEmpty,
           let decoded = try? JSONDecoder().decode(UserProfile.self, from: profileData) {
            profile = decoded
            if let dob = decoded.dateOfBirth {
                dobDate = dob
                hasDob = true
            }
        }
        if !customCategoriesData.isEmpty,
           let decoded = try? JSONDecoder().decode([String].self, from: customCategoriesData) {
            customCategories = decoded
        }
    }

    private func save() {
        profile.dateOfBirth = hasDob ? dobDate : nil
        if let encoded = try? JSONEncoder().encode(profile) {
            profileData = encoded
        }
        if let encoded = try? JSONEncoder().encode(customCategories) {
            customCategoriesData = encoded
        }
        dismiss()
    }

    private func handleHMRCToggle(_ enabled: Bool) {
        if enabled {
            Task {
                let granted = await HMRCDeadlineNotifications.requestAuthorisation()
                await MainActor.run {
                    if granted {
                        HMRCDeadlineNotifications.reschedule()
                    } else {
                        // Permission denied — flip the toggle back off so the
                        // UI doesn't lie about what's actually scheduled.
                        hmrcRemindersEnabled = false
                    }
                }
            }
        } else {
            HMRCDeadlineNotifications.cancelAll()
        }
    }

    private func refreshRate() {
        isRefreshingRate = true
        Task {
            let rate = await ExchangeRateService.latestUSDPerGBP()
            await MainActor.run {
                isRefreshingRate = false
                if let r = rate, r > 0 {
                    usdRate = r
                    usdRateUpdatedAt = Date().timeIntervalSince1970
                }
            }
        }
    }

    private func signOut() {
        // Persist any pending profile edits before locking, so the user doesn't
        // lose changes when they tap Sign out without saving first.
        profile.dateOfBirth = hasDob ? dobDate : nil
        if let encoded = try? JSONEncoder().encode(profile) {
            profileData = encoded
        }
        if let encoded = try? JSONEncoder().encode(customCategories) {
            customCategoriesData = encoded
        }
        loginManager.signOut()
        dismiss()
    }

    private func addCategory() {
        let trimmed = newCategoryName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !customCategories.contains(trimmed) else { return }
        customCategories.append(trimmed)
        newCategoryName = ""
    }

    private func deleteAll() {
        AttachmentStore.shared.deleteAll()
        profileData = Data()
        entriesData = Data()
        customCategoriesData = Data()
        loginManager.resetAccount()
        dismiss()
    }
}

// MARK: - What's New

private struct ReleaseNote: Identifiable {
    let id = UUID()
    let version: String
    let date: String
    let bullets: [String]
}

private let releaseNotes: [ReleaseNote] = [
    .init(version: "0.23", date: "Jun 2026", bullets: [
        "Comparison cards on Dashboard — \"vs last month\" (calendar) and \"vs last year\" (UK tax year) show this period's profit with the % change vs the previous one, arrow-tinted sage for positive and alert red for negative"
    ]),
    .init(version: "0.22", date: "Jun 2026", bullets: [
        "Tax-year PDF export — Settings → Data → \"Export tax-year PDF\" generates an A4 portrait summary (profile + tax code, year totals, income tax & NI estimates, MTD-IT quarterly profits) and hands it to the share sheet, ready to email an accountant"
    ]),
    .init(version: "0.21", date: "Jun 2026", bullets: [
        "HMRC deadline reminders — toggle in Settings → Reminders schedules 30-day, 7-day and morning-of notifications for the 31 January balancing payment and the 31 July second payment on account",
        "Permission prompt is requested when the toggle flips on; denial bounces the toggle back to off so the UI never lies about what's scheduled"
    ]),
    .init(version: "0.20", date: "Jun 2026", bullets: [
        "MTD-IT quarterly view on the Tax summary — four cards covering Q1 6 Apr–5 Jul through Q4 6 Jan–5 Apr, each showing profit and the income − expenses figures behind it (allowable only)"
    ]),
    .init(version: "0.19", date: "Jun 2026", bullets: [
        "Refined Income Tax estimate that honours per-entry income types",
        "PAYE income excluded (treated as taxed at source)",
        "Dividends use the 2025/26 £500 allowance and 8.75% / 33.75% / 39.35% bands, stacked on top of ordinary income",
        "Savings interest uses the £1,000 Personal Savings Allowance then ordinary rates",
        "Freelance + rental + other income still routes through the standard SA bands"
    ]),
    .init(version: "0.18", date: "Jun 2026", bullets: [
        "Income type on income entries — Freelance, PAYE, Dividend, Rental, Savings interest, Other (defaults to Freelance for existing entries)"
    ]),
    .init(version: "0.17", date: "Jun 2026", bullets: [
        "Allowable / disallowable toggle on expense entries (defaults to allowable)",
        "Tax summary deducts only allowable expenses when computing taxable profit; income tax & NI estimates use the new profit",
        "When disallowable expenses exist, the Expenses card sprouts an Allowable / Disallowable split below"
    ]),
    .init(version: "0.16", date: "Jun 2026", bullets: [
        "\"New category…\" row inside the entry form's category picker — name it in the prompt and the new category is saved and selected without leaving the form"
    ]),
    .init(version: "0.15", date: "Jun 2026", bullets: [
        "Today / This week / This month / All quick chips above the category chips on the entry lists",
        "Date-range filter stacks with the category chip + search box — Clear filters wipes all three"
    ]),
    .init(version: "0.14", date: "Jun 2026", bullets: [
        "Vendor / Payer field on entries — separate from description, label flips with entry type (\"Vendor\" for expense, \"Payer\" for income)",
        "Search now matches vendor as well as description and category",
        "Entry rows show the vendor as the primary line when set, with description as the meta"
    ]),
    .init(version: "0.13", date: "Jun 2026", bullets: [
        "Recent activity card on the Dashboard — last 5 entries, tap to edit"
    ]),
    .init(version: "0.12", date: "Jun 2026", bullets: [
        "Pull-to-refresh on Expenses + Income — re-runs the recurring auto-gen pass and refreshes the USD rate in one gesture"
    ]),
    .init(version: "0.11", date: "Jun 2026", bullets: [
        "Haptic feedback throughout — success tap on save / sign-in / Face ID, light impact on duplicate / sign-out, warning on delete, error on bad verification code"
    ]),
    .init(version: "0.10", date: "Jun 2026", bullets: [
        "Per-entry VAT — Standard / Reduced / Zero-rated / Exempt / Unspecified",
        "Tax Summary VAT card now splits into Declared (from explicit rates) and Estimated (20% fallback for Unspecified)",
        "Swift Charts on the Dashboard: monthly profit bars + expenses-by-category donut",
        "Settings → Data → \"Load sample tax year\" — drops in ~30 representative entries with mixed currencies, recurrence, durations, and VAT so the Dashboard, charts and Tax Summary populate instantly"
    ]),
    .init(version: "0.9", date: "Jun 2026", bullets: [
        "Notes field on entries — free-form multi-line text below the details",
        "Swipe right on a row to duplicate; swipe left to delete (cleans up the attached PDF too)",
        "Tax summary now shows three estimate cards: VAT included in expenses (20%), Income Tax due (current PA + 2025/26 bands), Class 4 NI due (6%/2%)",
        "Estimates fall back to standard assumptions when entries don't carry explicit VAT or tax-status detail — refined later when per-entry VAT flags are added"
    ]),
    .init(version: "0.8", date: "Jun 2026", bullets: [
        "Search bar on the Expenses + Income tabs (matches description and category)",
        "Category filter chips below the page header — tap to scope, tap again to clear",
        "\"5 of 23 entries\" counter in the page subtitle when filters are active",
        "Recurring entries now auto-materialise on app launch — every monthly/yearly/etc. cycle that has elapsed since the template's last run becomes a real entry, marked with an \"Auto\" chip",
        "Auto-generation respects the entry's Duration — generation stops at template.date + duration",
        "Editing a child preserves its link to the recurrence template; editing a template keeps its last-generated marker so old cycles aren't re-spawned"
    ]),
    .init(version: "0.7", date: "Jun 2026", bullets: [
        "Sign out from Settings — locks the app without wiping data",
        "Tax year picker in the nav bar; every tab filters to the active year",
        "Amount field accepts arithmetic (e.g. 12.99 + 5.50) with a live preview",
        "CSV export of every entry from Settings → Data",
        "Live USD rate fetch — refreshes every 12h, manual refresh in Settings",
        "Face ID / Touch ID / Optic ID toggle in Settings → Session",
        "Entry rows: cleaner two-line layout, combined recurrence·duration pill",
        "Long lists scroll reliably (List replaces ScrollView+Buttons)",
        "Custom categories now reliably select and save",
        "Sign In is the default landing screen; \"Already have an account?\" always visible on Sign Up",
        "Verification demo code stays readable in dark mode"
    ]),
    .init(version: "0.6", date: "Jun 2026", bullets: [
        "New recurrence: Every 3 years",
        "Recurrence × Duration now produces a commitment total — Dashboard & Tax summary sum the full term",
        "Live total preview in the entry form, with a warning when duration is shorter than one cycle",
        "Custom categories — add your own from Settings",
        "What's New + FAQ available from the help menu"
    ]),
    .init(version: "0.5", date: "Jun 2026", bullets: [
        "UK Income Tax + Class 4 NI band reference cards on Tax Summary",
        "Tax-code quick-pick menu in Settings",
        "Bug fix: parseTaxCode now returns the correct personal allowance"
    ]),
    .init(version: "0.4", date: "Jun 2026", bullets: [
        "Settings: Name, NI number, Address, Date of birth",
        "Light / Dark / System appearance toggle",
        "Delete all data with confirmation"
    ]),
    .init(version: "0.3", date: "Jun 2026", bullets: [
        "Currency on each entry (GBP / USD) with live GBP equivalent",
        "PDF attachments — pick, share, swipe-to-delete",
        "Categories for Domain names, Web hosting, SSL Certificates, GenAI"
    ]),
    .init(version: "0.2", date: "Jun 2026", bullets: [
        "tally.css brand system applied throughout",
        "Wordmark + \"Tax made human.\" strap on every page",
        "Renamed to UK Expense Tracker"
    ]),
    .init(version: "0.1", date: "Jun 2026", bullets: [
        "Email sign-up + verification + sign-in",
        "Face ID / Touch ID / Optic ID sign-in after first password sign-in"
    ])
]

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    TallyPageHeader(title: "What's New",
                                    subtitle: "Recent improvements to Tally")

                    VStack(spacing: T.space4) {
                        ForEach(releaseNotes) { note in
                            ReleaseCard(note: note)
                        }
                    }
                    .padding(.horizontal, T.space6)
                    .padding(.bottom, T.space8)
                }
            }
            .background(C.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ReleaseCard: View {
    let note: ReleaseNote
    var body: some View {
        VStack(alignment: .leading, spacing: T.space3) {
            HStack {
                Text("v\(note.version)")
                    .font(.system(size: T.textMd, weight: .bold))
                    .foregroundColor(C.ink)
                Spacer()
                Text(note.date)
                    .font(.eyebrow)
                    .foregroundColor(C.sage)
            }
            VStack(alignment: .leading, spacing: T.space2) {
                ForEach(note.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: T.space2) {
                        Circle()
                            .fill(C.sageLight)
                            .frame(width: 6, height: 6)
                            .padding(.top, 7)
                        Text(bullet)
                            .font(.system(size: T.textSm))
                            .foregroundColor(C.mid)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(T.space5)
        .background(C.white)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(C.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

// MARK: - FAQ

private struct FAQItem: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

private let faqItems: [FAQItem] = [
    .init(
        question: "How is my data stored?",
        answer: "Everything stays on your device. Entries, your profile, attachments, and your account live in UserDefaults and the app's Documents folder — nothing is sent to a server."
    ),
    .init(
        question: "What does Recurrence × Duration mean for the total?",
        answer: "When an entry has both — for example monthly £10 for 1 year, or yearly £100 for 3 years — the Dashboard and Tax summary count the full committed amount (£120 and £300 respectively). Without a duration, only the per-period amount is recorded."
    ),
    .init(
        question: "What is the \"Auto\" chip on an entry?",
        answer: "It marks an entry that was auto-created by the recurrence engine on app launch. You created the original template (e.g. \"Hosting fee, monthly, £20\") and Tally automatically materialised one entry per month since then, so the dashboard totals stay accurate without you re-adding each cycle. Edit or delete auto entries like any other."
    ),
    .init(
        question: "How do I stop a recurring entry from generating more?",
        answer: "Open the template (the original, non-Auto entry), set its Recurrence to None, and Save. Existing auto-generated children stay where they are; no new ones will be created. Setting a Duration on the template also caps generation at template.date + duration."
    ),
    .init(
        question: "How does USD → GBP conversion work?",
        answer: "Each entry remembers its own currency. Totals are normalised to GBP using the `usdRate` setting, which is the standard GBP/USD market quote (USD per 1 GBP). The default is 1.25, meaning 1 GBP ≈ 1.25 USD."
    ),
    .init(
        question: "Where does the personal allowance come from?",
        answer: "Your tax code in Settings drives it. The digits × 10 gives the allowance (so 1257L → £12,570). Special codes (BR, D0, D1, NT, 0T) are treated as zero allowance — the whole income is taxed at the band's flat rate."
    ),
    .init(
        question: "How do I attach a receipt?",
        answer: "Open an entry → Attachments section → tap \"Add PDF\". The PDF is copied into Tally's sandbox. Tap the share icon to export it, or swipe left to delete it (and the underlying file)."
    ),
    .init(
        question: "Why doesn't Google / Facebook sign-in work yet?",
        answer: "The SDKs are wired up, but you still need to add an OAuth client ID (Google) or app ID/client token (Facebook) plus the matching URL Type. See the README's Configuration section for the exact steps."
    ),
    .init(
        question: "Will my Face ID button always be there?",
        answer: "Only after you've signed in with a password at least once. Biometrics unlock an existing session — they don't create one. If you delete all data, you'll need to sign in with a password again before Face ID reappears."
    ),
    .init(
        question: "How do I delete everything?",
        answer: "Settings → Danger zone → Delete all data. This permanently removes your profile, entries, attachments, custom categories, and account. You'll be returned to Sign Up."
    )
]

struct FAQView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    TallyPageHeader(title: "FAQ", subtitle: "Quick answers to common questions")

                    VStack(spacing: T.space3) {
                        ForEach(faqItems) { item in
                            FAQRow(item: item)
                        }
                    }
                    .padding(.horizontal, T.space6)
                    .padding(.bottom, T.space8)
                }
            }
            .background(C.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct FAQRow: View {
    let item: FAQItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: T.space3) {
            Button {
                withAnimation(.easeInOut(duration: T.transitionFast)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .top) {
                    Text(item.question)
                        .font(.system(size: T.textSm, weight: .bold))
                        .foregroundColor(C.ink)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundColor(C.sage)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(item.answer)
                    .font(.system(size: T.textSm))
                    .foregroundColor(C.mid)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(T.space4)
        .background(C.white)
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous)
                .stroke(C.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: T.radiusLg, style: .continuous))
    }
}

