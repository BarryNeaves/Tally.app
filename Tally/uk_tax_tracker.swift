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
    // Primary Palette
    static let primary = Color(red: 0.0, green: 0.5, blue: 0.8)
    static let secondary = Color(red: 0.9, green: 0.6, blue: 0.2)
    static let green = Color.green
    static let red = Color.red
    
    // Backgrounds
    static let background = Color(UIColor.systemBackground)
    static let cardBackground = Color(UIColor.secondarySystemBackground)
    
    // Text
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    // Additional colors from design tokens (hex codes)
    static let sage = Color(hex: "#9DC9BC")           // sage
    static let sageLight = Color(hex: "#B4D8D3")      // sageLight
    static let sagePale = Color(hex: "#E5F4F1")       // sagePale
    static let mint = Color(hex: "#B8D8D8")           // mint
    static let paper = Color(hex: "#F0F0F0")          // paper
    static let ink = Color(hex: "#222222")            // ink
    static let mid = Color(hex: "#555555")            // mid
    static let rule = Color(hex: "#CCCCCC")           // rule
    static let amber = Color(hex: "#FFC107")          // amber
    static let amberPale = Color(hex: "#FFF8E1")      // amberPale
    static let alert = Color(hex: "#D32F2F")          // alert
    static let white = Color.white                      // white
    static let darkBase = Color(hex: "#121212")       // darkBase
    static let darkCard = Color(hex: "#1E1E1E")       // darkCard
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
    // Typography - font sizes in points
    static let fontDisplay: CGFloat = 28
    static let fontBody: CGFloat = 16
    static let fontEyebrow: CGFloat = 12
    static let fontDataLabel: CGFloat = 10
    static let fontHeroNumber: CGFloat = 52
    
    // Spacing - standard spacing values in points
    static let spacingXs: CGFloat = 4
    static let spacingSm: CGFloat = 8
    static let spacingMd: CGFloat = 16
    static let spacingLg: CGFloat = 24
    static let spacingXl: CGFloat = 32
    
    // Radius - corner radius
    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12
    
    // Shadow - standard shadow
    static let shadowSm = Shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
    static let shadowMd = Shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 4)
    
    // Transition - animation duration in seconds
    static let transitionFast = 0.15
    static let transitionNormal = 0.3
    static let transitionSlow = 0.5
    
    // Shadow struct for convenience
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
}

// MARK: - Font Extensions for Common Text Styles

extension Font {
    static var display: Font {
        Font.system(size: T.fontDisplay, weight: .bold, design: .default)
    }
    static var bodyText: Font {
        Font.system(size: T.fontBody, weight: .regular, design: .default)
    }
    static var eyebrow: Font {
        Font.system(size: T.fontEyebrow, weight: .semibold, design: .default).smallCaps()
    }
    static var dataLabel: Font {
        Font.system(size: T.fontDataLabel, weight: .regular, design: .default)
    }
    static var heroNumber: Font {
        Font.system(size: T.fontHeroNumber, weight: .heavy, design: .default)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Create your Tally account")
                    .font(.title).bold()
                    .multilineTextAlignment(.center)
                    .padding(.top, 60)
                    .padding(.horizontal)

                VStack(spacing: 14) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password (min 8 characters)", text: $password)
                        .textContentType(.newPassword)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Confirm password", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 32)

                if let error = loginManager.formError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(C.alert)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    loginManager.signUp(email: email, password: password, confirmPassword: confirmPassword)
                } label: {
                    Text("Create Account")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(C.primary)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 32)

                if !loginManager.storedEmail.isEmpty {
                    Button("Already have an account? Sign In") {
                        loginManager.goToSignIn()
                    }
                    .font(.subheadline)
                }

                Spacer(minLength: 20)
            }
        }
        .background(C.background.edgesIgnoringSafeArea(.all))
    }
}

struct VerifyEmailView: View {
    @ObservedObject var loginManager: LoginManager
    @State private var code: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Verify your email")
                    .font(.title).bold()
                    .padding(.top, 60)

                Text("Enter the 6-digit code we sent to\n\(loginManager.storedEmail)")
                    .multilineTextAlignment(.center)
                    .foregroundColor(C.textSecondary)
                    .padding(.horizontal, 32)

                if let pending = loginManager.pendingVerificationCode {
                    VStack(spacing: 6) {
                        Text("Demo code (no email sent yet)")
                            .font(.caption2.smallCaps())
                            .foregroundColor(C.textSecondary)
                        Text(pending)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(C.amberPale)
                            .cornerRadius(6)
                    }
                }

                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 60)

                if let error = loginManager.formError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(C.alert)
                }

                Button {
                    loginManager.verifyEmail(code: code)
                } label: {
                    Text("Verify Email")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(C.primary)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 32)

                Button("Resend Code") {
                    loginManager.issueVerificationCode()
                }
                .font(.subheadline)

                Button("Start over") {
                    loginManager.resetAccount()
                }
                .font(.caption)
                .foregroundColor(C.textSecondary)

                Spacer(minLength: 20)
            }
        }
        .background(C.background.edgesIgnoringSafeArea(.all))
    }
}

struct SignInView: View {
    @ObservedObject var loginManager: LoginManager
    @State private var email: String = ""
    @State private var password: String = ""

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
            VStack(spacing: 24) {
                Text("Welcome back")
                    .font(.title).bold()
                    .padding(.top, 60)

                VStack(spacing: 14) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 32)

                if let error = loginManager.formError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(C.alert)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    loginManager.signIn(email: email, password: password)
                } label: {
                    Text("Sign In")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(C.primary)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 32)

                if loginManager.canUseBiometrics {
                    Button {
                        loginManager.loginWithBiometrics()
                    } label: {
                        HStack {
                            Image(systemName: biometricIcon)
                            Text(biometricLabel)
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(C.sage)
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 32)
                }

                if let bioError = loginManager.biometricError {
                    Text(bioError)
                        .font(.caption)
                        .foregroundColor(C.alert)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button("New here? Create an account") {
                    loginManager.goToSignUp()
                }
                .font(.subheadline)

                Spacer(minLength: 20)
            }
            .onAppear {
                if email.isEmpty { email = loginManager.storedEmail }
            }
        }
        .background(C.background.edgesIgnoringSafeArea(.all))
    }
}

