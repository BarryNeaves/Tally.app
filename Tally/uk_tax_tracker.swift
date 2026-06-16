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

    /// Face ID/Touch ID is only offered after at least one successful password sign-in.
    var canUseBiometrics: Bool {
        hasSignedInOnce && availableBiometryType != .none
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
            return
        }
        defaults.set(true, forKey: emailVerifiedKey)
        pendingVerificationCode = nil
        formError = nil
        step = .signIn
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
    }

    func signOut() {
        step = .signIn
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
                } else {
                    self.biometricError = evalError?.localizedDescription ?? "Biometric authentication failed."
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
        // TODO: Integrate Google Sign-In SDK here
        
        let config = GIDConfiguration(clientID: Self.googleClientID)
        
        // The presentingViewController is required for the sign-in flow.
        // Since we are in SwiftUI, you may need to get the root view controller:
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
            guard let user = signInResult?.user else {
                print("Google Sign-In user data not available")
                return
            }
            // Successful sign in
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

    private static func escape(_ field: String) -> String {
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
                                DashboardView(entries: entriesForSelectedYear, taxYear: taxYear, usdRate: usdRate)
                            case 1:
                                EntryListView(
                                    entries: entriesForSelectedYear.filter { $0.type == .expense },
                                    title: "Expenses",
                                    usdRate: usdRate,
                                    onEdit: editEntry,
                                    onAddNew: addNewEntry
                                )
                            case 2:
                                EntryListView(
                                    entries: entriesForSelectedYear.filter { $0.type == .income },
                                    title: "Income",
                                    usdRate: usdRate,
                                    onEdit: editEntry,
                                    onAddNew: addNewEntry
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
                    .onAppear(perform: loadEntries)
                    .sheet(isPresented: $showEntryModal) {
                        EntryModalView(entry: $editingEntry, usdRate: usdRate, customCategoryNames: customCategoryNames, onSave: saveEntry, onCancel: cancelEntry)
                    }
                    .sheet(isPresented: $showSettings) {
                        SettingsView(
                            profileData: $profileData,
                            entriesData: $entriesData,
                            appearanceMode: $appearanceMode,
                            taxCode: $taxCode,
                            customCategoriesData: $customCategoriesData,
                            entries: entries,
                            usdRate: usdRate,
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
            recurrence: .none,
            duration: nil,
            attachments: nil
        )
        showEntryModal = true
    }

    private func editEntry(_ entry: Entry) {
        editingEntry = entry
        showEntryModal = true
    }

    private func saveEntry(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        saveEntries()
        showEntryModal = false
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
    var entries: [Entry]
    var taxYear: Int
    var usdRate: Double

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

struct EntryListView: View {
    var entries: [Entry]
    var title: String
    var usdRate: Double
    var onEdit: (Entry) -> Void
    var onAddNew: () -> Void

    var body: some View {
        // Using a List (rather than ScrollView + Buttons) for the rows — Lists
        // own their scroll gesture and don't compete with row taps, so long
        // entry lists reliably scroll on real devices.
        List {
            Section {
                TallyPageHeader(title: title,
                                subtitle: "\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if entries.isEmpty {
                    Text("No \(title.lowercased()) yet")
                        .font(.bodyText)
                        .foregroundColor(C.mid)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, T.space6)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(entries) { entry in
                        EntryRow(entry: entry, usdRate: usdRate)
                            .contentShape(Rectangle())
                            .onTapGesture { onEdit(entry) }
                            .listRowInsets(EdgeInsets(top: 6, leading: T.space6,
                                                      bottom: 6, trailing: T.space6))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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
                    Text(entry.description.isEmpty ? entry.category.name : entry.description)
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
    private var expenses: Double {
        entries.filter { $0.type == .expense }
            .map { $0.totalAmountInGBP(usdRate: usdRate) }
            .reduce(0, +)
    }
    private var profit: Double { income - expenses }
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

                    SummaryCard(label: "Personal allowance",
                                value: fmt(personalAllowance),
                                accent: C.amber,
                                style: .amber)

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

    @State private var descriptionText: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = Date()
    @State private var selectedType: Entry.EntryType = .expense
    @State private var recurrence: Recurrence = .none
    @State private var duration: Duration? = nil
    @State private var currency: Currency = .gbp
    @State private var attachments: [PDFAttachment] = []
    @State private var showFileImporter = false

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
                        currency: currency
                    )
                    onSave(newEntry)
                }
                .disabled(descriptionText.isEmpty || amountAsDouble == nil || selectedCategoryName.isEmpty)
            )
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
                } else {
                    selectedCategoryName = categories.first?.name ?? ""
                    recurrence = .none
                    duration = nil
                    currency = .gbp
                    attachments = []
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
                    Text("Enter the 6-digit code we sent to ")
                        .font(.bodyText)
                        .foregroundColor(C.mid)
                    + Text(loginManager.storedEmail)
                        .font(.system(size: T.textBase, weight: .semibold))
                        .foregroundColor(C.ink)
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
    var entries: [Entry]
    var usdRate: Double
    @ObservedObject var loginManager: LoginManager
    @Environment(\.dismiss) private var dismiss

    @State private var profile = UserProfile()
    @State private var dobDate = Date()
    @State private var hasDob = false
    @State private var showDeleteConfirm = false
    @State private var customCategories: [String] = []
    @State private var newCategoryName: String = ""

    private var exportURL: URL? {
        let csv = EntryCSV.makeCSV(entries: entries, usdRate: usdRate)
        let stamp = DateFormatter.tallyExportStamp.string(from: Date())
        let filename = "tally-entries-\(stamp).csv"
        return try? EntryCSV.writeToTemp(csv: csv, filename: filename)
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
                } header: {
                    Text("Data")
                } footer: {
                    Text("Opens the share sheet with a CSV of every entry — date, description, type, category, amount, currency, GBP equivalent, recurrence/duration, and attachment count.")
                }

                Section {
                    Button {
                        signOut()
                    } label: {
                        Label("Sign out", systemImage: "lock.fill")
                    }
                } header: {
                    Text("Session")
                } footer: {
                    Text("Locks the app. Your data stays put — sign in again with your password (or Face ID).")
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

