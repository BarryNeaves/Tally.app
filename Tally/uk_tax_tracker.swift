//
//  uk_tax_tracker.swift
//

import SwiftUI
import Combine
import GoogleSignIn
import FacebookLogin
import LocalAuthentication
import CryptoKit

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
    case none, weekly, fortnightly, monthly, yearly
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
        if storedEmail.isEmpty {
            step = .signUp
        } else if !isEmailVerified {
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
    guard let year = components.year, let month = components.month else { return 2026 }
    // UK tax year runs from April 6 to April 5 next year
    if month >= 4 {
        return year
    } else {
        return year - 1
    }
}

// MARK: - Color Constants
// Color tokens taken from the CSS design system

struct C {
    // Brand palette — sourced from tally.css :root tokens
    static let sage = Color(hex: "#4A7C59")           // Primary CTA, active states
    static let sageLight = Color(hex: "#6BA87A")      // Income, positive values
    static let sagePale = Color(hex: "#EEF5F0")       // Card fills, section bg
    static let mint = Color(hex: "#B8DFC4")           // Badges, soft borders
    static let paper = Color(hex: "#F7F6F1")          // App background (light)
    static let ink = Color(hex: "#1A1C18")            // Primary text
    static let mid = Color(hex: "#4A4D46")            // Secondary text
    static let rule = Color(hex: "#DDE0D8")           // Dividers, borders
    static let amber = Color(hex: "#D4862A")          // Tax callouts, crossbar
    static let amberPale = Color(hex: "#FFF3E0")      // Amber card background
    static let alert = Color(hex: "#E05252")          // Errors, delete, overdue
    static let usd = Color(hex: "#F7A928")            // USD accent
    static let white = Color.white

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

func fmt(_ amount: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "GBP"
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: amount)) ?? "£0.00"
}

func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    return formatter.string(from: date)
}

func parseTaxCode(_ code: String) -> Int? {
    // UK tax code is typically numbers followed by a letter, e.g. 1257L
    // Extract numeric part and multiply by 10 to get personal allowance
    let numericPart = code.trimmingCharacters(in: CharacterSet.letters.inverted)
    if let number = Int(numericPart) {
        return number * 10
    }
    return nil
}

// MARK: - Main View

struct UkTaxTrackerView: View {
    // Data storage
    @AppStorage("entriesData") private var entriesData: Data = Data()
    @AppStorage("taxYear") private var taxYear: Int = currentTaxYear()
    @AppStorage("taxCode") private var taxCode: String = "1257L"
    @AppStorage("usdRate") private var usdRate: Double = 1.25

    @State private var entries: [Entry] = []
    @State private var selectedTab = 0
    @State private var showEntryModal = false
    @State private var editingEntry: Entry?
    @State private var toastMessage: String?
    @State private var toastTimer: Timer?
    
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

                        // Tab content
                        Group {
                            switch selectedTab {
                            case 0:
                                DashboardView(entries: entries, taxYear: taxYear)
                            case 1:
                                EntryListView(
                                    entries: entries.filter { $0.type == .expense },
                                    title: "Expenses",
                                    onEdit: editEntry,
                                    onAddNew: addNewEntry
                                )
                            case 2:
                                EntryListView(
                                    entries: entries.filter { $0.type == .income },
                                    title: "Income",
                                    onEdit: editEntry,
                                    onAddNew: addNewEntry
                                )
                            case 3:
                                SummaryView(entries: entries, taxYear: taxYear, taxCode: taxCode, usdRate: usdRate)
                            default:
                                Text("Unknown Tab")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .navigationTitle("UK Tax Tracker")
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(action: {
                                addNewEntry()
                            }) {
                                Image(systemName: "plus")
                            }
                        }
                    }
                    .tint(C.sage)
                    .onAppear(perform: loadEntries)
                    .sheet(isPresented: $showEntryModal) {
                        EntryModalView(entry: $editingEntry, onSave: saveEntry, onCancel: cancelEntry)
                    }
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
            recurrence: .none
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Dashboard")
                    .font(.title2)
                    .bold()
                    .padding(.bottom, 8)

                // Placeholder summary cards and charts
                Text("Summary and charts will appear here.")
                    .foregroundColor(.secondary)

                // TODO: Implement dashboard UI with summaries of totals, graphs, etc.
            }
            .padding()
        }
        .background(C.background)
    }
}

struct EntryListView: View {
    var entries: [Entry]
    var title: String
    var onEdit: (Entry) -> Void
    var onAddNew: () -> Void

    var body: some View {
        VStack {
            if entries.isEmpty {
                Spacer()
                Text("No \(title.lowercased()) entries")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(entries) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.description)
                                    .font(.headline)
                                Text(shortDate(entry.date))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(fmt(entry.amount))
                                .foregroundColor(entry.type == .expense ? C.red : C.green)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onEdit(entry)
                        }
                    }
                    .onDelete { indexSet in
                        // Optional: implement deletion
                    }
                }
                .listStyle(PlainListStyle())
            }
            Button(action: onAddNew) {
                Label("Add \(title.dropLast())", systemImage: "plus.circle")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(C.primary.opacity(0.1))
                    .cornerRadius(8)
                    .padding([.horizontal, .bottom])
            }
        }
    }
}

struct SummaryView: View {
    var entries: [Entry]
    var taxYear: Int
    var taxCode: String
    var usdRate: Double

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tax Summary for \(taxYear)/\(taxYear + 1)")
                    .font(.title2)
                    .bold()
                    .padding(.bottom, 8)

                // Placeholder for tax summary calculations and display
                Text("Summary of income, expenses, tax liabilities, and conversions.")
                    .foregroundColor(.secondary)

                // TODO: Calculate personal allowance from taxCode, income totals, tax due, etc.
            }
            .padding()
        }
        .background(C.background)
    }
}

struct EntryModalView: View {
    @Binding var entry: Entry?
    var onSave: (Entry) -> Void
    var onCancel: () -> Void

    @State private var descriptionText: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = Date()
    @State private var selectedType: Entry.EntryType = .expense
    @State private var recurrence: Recurrence = .none

    // Static categories for example
    let categories = [
        Category(id: UUID(), name: "General", colorName: "primary"),
        Category(id: UUID(), name: "Food", colorName: "orange"),
        Category(id: UUID(), name: "Transport", colorName: "blue"),
        Category(id: UUID(), name: "Salary", colorName: "green"),
        Category(id: UUID(), name: "Tax", colorName: "red")
    ]

    @State private var selectedCategory: Category?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Details")) {
                    TextField("Description", text: $descriptionText)
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Type", selection: $selectedType) {
                        Text("Expense").tag(Entry.EntryType.expense)
                        Text("Income").tag(Entry.EntryType.income)
                        Text("Tax").tag(Entry.EntryType.tax)
                    }
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categories) { category in
                            Text(category.name).tag(category as Category?)
                        }
                    }
                    Picker("Recurrence", selection: $recurrence) {
                        ForEach(Recurrence.allCases, id: \.self) { rec in
                            Text(rec.rawValue.capitalized).tag(rec)
                        }
                    }
                }
            }
            .navigationTitle(entry == nil ? "New Entry" : "Edit Entry")
            .navigationBarItems(
                leading: Button("Cancel") {
                    onCancel()
                },
                trailing: Button("Save") {
                    guard let amount = Double(amountText),
                          let selectedCategory = selectedCategory else { return }
                    let newEntry = Entry(
                        id: entry?.id ?? UUID(),
                        date: date,
                        description: descriptionText,
                        amount: amount,
                        type: selectedType,
                        category: selectedCategory,
                        recurrence: recurrence == .none ? nil : recurrence
                    )
                    onSave(newEntry)
                }
                .disabled(descriptionText.isEmpty || Double(amountText) == nil || selectedCategory == nil)
            )
            .onAppear {
                if let entry = entry {
                    descriptionText = entry.description
                    amountText = String(entry.amount)
                    date = entry.date
                    selectedType = entry.type
                    selectedCategory = entry.category
                    recurrence = entry.recurrence ?? .none
                } else {
                    selectedCategory = categories.first
                    recurrence = .none
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

                if !loginManager.storedEmail.isEmpty {
                    Button("Already have an account? Sign In") {
                        loginManager.goToSignIn()
                    }
                    .font(.system(size: T.textSm, weight: .semibold))
                    .foregroundColor(C.sage)
                }

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
                            .foregroundColor(C.amber)
                        Text(pending)
                            .font(.system(size: T.textXl, weight: .bold, design: .monospaced))
                            .foregroundColor(C.ink)
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

