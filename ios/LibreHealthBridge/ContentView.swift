import BridgeCore
import SwiftUI
import UIKit

private enum AppTab: Hashable {
    case home, details, information
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showLogin = false
    @State private var showLogout = false
    @State private var showSetup = false
    @State private var showHomeSyncSuccess = false
    @State private var selectedTab: AppTab = .home
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var readyForSync: Bool {
        model.isVerified && model.healthAccess == .authorized
    }

    // Screenshot routing is deliberately unavailable in device and release builds.
    #if DEBUG && targetEnvironment(simulator)
        @State private var didRouteLaunch = false
        private func routeLaunchScreen() {
            guard !didRouteLaunch else { return }
            didRouteLaunch = true
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--ui-screen"),
                arguments.indices.contains(index + 1)
            else { return }
            switch arguments[index + 1] {
            case "home": selectedTab = .home
            case "details": selectedTab = .details
            case "information": selectedTab = .information
            case "login":
                selectedTab = .home
                showLogin = true
            case "setup":
                selectedTab = .home
                showSetup = true
            default: break
            }
        }
    #endif

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                home
            }
            .tabItem { Label("tab.home", systemImage: "heart") }
            .tag(AppTab.home)

            NavigationStack {
                DetailsView(model: model, configure: { showSetup = true })
            }
            .tabItem { Label("common.details", systemImage: "chart.bar.xaxis") }
            .tag(AppTab.details)

            NavigationStack {
                InformationView()
            }
            .tabItem { Label("tab.information", systemImage: "info.circle") }
            .tag(AppTab.information)
        }
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                LoginView(model: model)
            }
            .privacyCovered()
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(model.isBusy)
        }
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                HealthSetupView(model: model)
            }
            .privacyCovered()
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(model.isBusy)
        }
        #if DEBUG && targetEnvironment(simulator)
            .onAppear(perform: routeLaunchScreen)
        #endif
        .alert("account.logOutConfirm", isPresented: $showLogout) {
            Button("account.logOut", role: .destructive) {
                Task { await model.logout() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("account.logOutExplanation")
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryCard

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeading("home.connection")
                    VStack(spacing: 0) {
                        statusRow(
                            "checklist.account",
                            symbol: "person.crop.circle",
                            color: .blue,
                            value: model.isSignedIn
                                ? "checklist.account.active"
                                : "checklist.account.inactive"
                        )
                        insetDivider
                        if model.isSignedIn {
                            statusRow(
                                "profile.current",
                                symbol: "person.text.rectangle",
                                color: .teal,
                                detail: selectedProfileName(model)
                            )
                            insetDivider
                            statusRow(
                                "health.name",
                                symbol: "heart.fill",
                                color: .pink,
                                value: LocalizedStringKey(
                                    model.healthAccess.rawValue
                                )
                            )
                        } else {
                            Text("checklist.profile.waiting")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                    .groupedCard()
                }

                if model.isSignedIn {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeading("checklist.account")
                        VStack(spacing: 0) {
                            Text("checklist.account.detail")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                            insetDivider
                            Button("account.logOut", role: .destructive) {
                                showLogout = true
                            }
                            .frame(
                                maxWidth: .infinity,
                                minHeight: 44,
                                alignment: .leading
                            )
                            .padding(.horizontal, 16)
                            .accessibilityIdentifier("account.logout")
                        }
                        .groupedCard()
                    }
                }
            }
            .disabled(model.isBusy)
            .frame(maxWidth: 600)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("tab.home")
        .navigationBarTitleDisplayMode(.large)
        .modifier(ActivityFeedbackModifier(model: model))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("home.summary", systemImage: "heart.text.square.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.pink)
            Text(
                model.isSignedIn
                    ? (readyForSync
                        ? "checklist.sync.active" : "checklist.sync.inactive")
                    : "checklist.account.inactive"
            )
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                model.isSignedIn
                    ? (readyForSync
                        ? "sync.explanation" : "checklist.sync.setupDetail")
                    : "checklist.intro"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if model.restoration == .retryableFailure && !model.isSignedIn {
                Button("profile.refresh") { Task { await model.restore() } }
            }
            if let lastSync = model.session?.report?.completedAt {
                VStack(alignment: .leading, spacing: 4) {
                    Text("details.lastSync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dateLabel(lastSync))
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .privacySensitive()
            }
            Divider()
            Button {
                guard model.isSignedIn else {
                    showLogin = true
                    return
                }
                model.refreshHealthAccess()
                if model.isVerified && model.healthAccess == .authorized {
                    Task {
                        let outcome = await model.sync()
                        if outcome == .success { showHomeSyncSuccess = true }
                    }
                } else {
                    showSetup = true
                }
            } label: {
                HStack {
                    Text(
                        !model.isSignedIn
                            ? "login.submit"
                            : readyForSync
                                ? "sync.start" : "checklist.sync.configure"
                    )
                }
                .font(.headline)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier(
                model.isSignedIn ? "health.sync" : "login.open"
            )
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .pink.opacity(0.12), .purple.opacity(0.04),
                                    .clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .alert("sync.succeeded", isPresented: $showHomeSyncSuccess) {
            Button("common.dismiss", role: .cancel) {}
        }
    }

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
    }

    private var insetDivider: some View {
        Divider()
            .padding(.leading, 56)
            .padding(.trailing, 16)
    }

    private func statusRow(
        _ title: LocalizedStringKey,
        symbol: String,
        color: Color,
        value: LocalizedStringKey? = nil,
        detail: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                if dynamicTypeSize.isAccessibilitySize {
                    if let value { Text(value).foregroundStyle(.secondary) }
                    if let detail {
                        Text(detail).foregroundStyle(.secondary)
                            .privacySensitive()
                    }
                }
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .privacySensitive()
                }
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 52, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct LoginView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                Label("login.welcome", systemImage: "heart.text.square")
                    .font(.headline)
                    .foregroundStyle(.pink)
                Text("login.explanation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("checklist.account") {
                TextField("login.email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("login.email")
                SecureField("login.password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("login.password")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    if await model.login(email: email, password: password) {
                        email = ""
                        password = ""
                        dismiss()
                    }
                }
            } label: {
                Text("login.submit")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || password.isEmpty
            )
            .accessibilityIdentifier("login.submit")
            .bottomActionLayout()
        }
        .disabled(model.isBusy)
        .privacySensitive()
        .navigationTitle("login.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("common.close", systemImage: "xmark") { dismiss() }
                    .disabled(model.isBusy)
            }
        }
        .modifier(ActivityFeedbackModifier(model: model))
        .onDisappear {
            email = ""
            password = ""
        }
    }
}

private struct HealthSetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingProfile: Connection?
    @State private var showProfileSwitch = false
    @State private var showHealthOpenFailure = false

    var body: some View {
        Form {
            profileSection
            if model.selectedPatientID != nil {
                if model.isVerified {
                    Section("health.setup.validate") {
                        Label(
                            "health.setup.confirmed",
                            systemImage: "checkmark.shield"
                        )
                        .foregroundStyle(.green)
                    }
                } else {
                    Section {
                        if let preview = model.snapshot?.preview,
                            let value = preview.valueMgDl,
                            let time = preview.timestamp
                        {
                            LabeledContent(
                                "reading.latest",
                                value: glucoseLabel(value)
                            )
                            LabeledContent(
                                "reading.measured",
                                value: dateLabel(time)
                            )
                        } else {
                            Text("health.setup.noLatestReading")
                                .foregroundStyle(.secondary)
                        }
                        if model.snapshot != nil && !model.isPreviewCurrent {
                            Text("health.setup.refreshRequired")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("reading.refresh") {
                            Task { await model.refresh() }
                        }
                        .accessibilityIdentifier("health.setup.refresh")
                    } header: {
                        Text("health.setup.validate")
                    } footer: {
                        Text("health.setup.validateDetail")
                    }
                }
            }
            Section {
                Label(
                    LocalizedStringKey(model.healthAccess.rawValue),
                    systemImage: "heart"
                )
                if model.healthAccess == .denied {
                    Text("health.setup.enableWrites").foregroundStyle(
                        .secondary
                    )
                }
                if model.healthAccess != .authorized
                    && model.healthAccess != .unavailable
                {
                    Button(
                        model.healthAccess == .denied
                            ? "health.setup.openHealth"
                            : "health.setup.requestPermission"
                    ) {
                        if model.healthAccess == .denied {
                            // HealthKit cannot show the authorization sheet again after denial.
                            // This scheme opens Health, but cannot deep-link to our permissions.
                            guard let healthURL = URL(string: "x-apple-health://") else {
                                showHealthOpenFailure = true
                                return
                            }
                            UIApplication.shared.open(healthURL) { opened in
                                if !opened {
                                    Task { @MainActor in showHealthOpenFailure = true }
                                }
                            }
                        } else {
                            Task { _ = await model.authorizeHealth() }
                        }
                    }
                    .disabled(!model.isVerified)
                    .alert("health.setup.openHealthFailed", isPresented: $showHealthOpenFailure) {
                        Button("common.close", role: .cancel) {}
                    } message: {
                        Text("health.setup.enableWrites")
                    }
                }
            } header: {
                Text("health.name")
            } footer: {
                Text("health.setup.explanation")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    if !model.isVerified {
                        guard await model.confirmPreview() else { return }
                    }
                    guard model.healthAccess == .authorized else { return }
                    // The sync refetches data and checks permission before writing.
                    let outcome = await model.sync()
                    if outcome == .success
                        || outcome == .completedWithStorageWarning
                    {
                        dismiss()
                    }
                }
            } label: {
                Text("health.setup.continue")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.healthAccess != .authorized
                    || (!model.isVerified
                        && (!model.isPreviewCurrent
                            || model.snapshot?.preview?.canValidate != true))
            )
            .accessibilityIdentifier("health.setup.sync")
            .bottomActionLayout()
        }
        .disabled(model.isBusy)
        .privacySensitive()
        .navigationTitle("health.setup.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("common.close", systemImage: "xmark") { dismiss() }
                    .disabled(model.isBusy)
            }
        }
        .modifier(ActivityFeedbackModifier(model: model))
        .onAppear { model.refreshHealthAccess() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshHealthAccess() }
        }
        .alert(
            "profile.switchConfirm",
            isPresented: $showProfileSwitch,
            presenting: pendingProfile
        ) { connection in
            Button("profile.switch") {
                Task { await model.selectConnection(connection.patientId) }
                pendingProfile = nil
            }
            Button("common.cancel", role: .cancel) { pendingProfile = nil }
        } message: { _ in
            Text("profile.switchExplanation")
        }
    }

    private var profileSection: some View {
        Section {
            Menu {
                ForEach(model.connections) { connection in
                    Button {
                        guard connection.patientId != model.selectedPatientID
                        else { return }
                        if model.selectedPatientID == nil {
                            Task {
                                await model.selectConnection(
                                    connection.patientId
                                )
                            }
                        } else {
                            pendingProfile = connection
                            showProfileSwitch = true
                        }
                    } label: {
                        if connection.patientId == model.selectedPatientID {
                            Label(
                                profileName(connection),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(profileName(connection))
                        }
                    }
                }
            } label: {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(selectedProfileName(model))
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                } label: {
                    Text("profile.current")
                }
            }
            .disabled(model.connections.isEmpty)
            .accessibilityLabel(Text("profile.choose"))
            .accessibilityValue(selectedProfileName(model))
            .accessibilityIdentifier("profile.select")

            if model.connections.isEmpty {
                Text("profile.none").foregroundStyle(.secondary)
            }
            Button("profile.refresh") { Task { await model.refresh() } }
                .accessibilityIdentifier("profile.refresh")
        } header: {
            Text("profile.choose")
        } footer: {
            Text(
                model.selectedPatientID == nil
                    ? "profile.selectionExplanation" : "profile.warning"
            )
        }
    }
}

private struct DetailsView: View {
    @Bindable var model: AppModel
    let configure: () -> Void

    var body: some View {
        List {
            if let report = model.session?.report {
                healthSection(report)
            } else {
                ContentUnavailableView {
                    Label("details.empty", systemImage: "chart.bar.xaxis")
                } description: {
                    Text(
                        !model.isSignedIn
                            ? "checklist.profile.waiting"
                            : model.selectedPatientID == nil
                                ? "details.setupRequired" : "details.noSync"
                    )
                } actions: {
                    if model.isSignedIn {
                        Button("checklist.sync.configure", action: configure)
                            .buttonStyle(.borderless)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .disabled(model.isBusy)
        .privacySensitive()
        .navigationTitle("common.details")
        .navigationBarTitleDisplayMode(.large)
        .modifier(ActivityFeedbackModifier(model: model))
    }

    private func healthSection(_ report: ImportReport) -> some View {
        Group {
            Section("details.healthSync") {
                LabeledContent(
                    "profile.current",
                    value: selectedProfileName(model)
                )
                LabeledContent(
                    "details.lastSync",
                    value: dateLabel(report.completedAt)
                )
                if let lastWrite = model.session?.lastWrite {
                    LabeledContent(
                        "sync.lastHealthWrite",
                        value: dateLabel(lastWrite)
                    )
                }
                Button("health.manage", action: configure)
                    .accessibilityIdentifier("details.health.configure")
            }
            Section("details.results") {
                LabeledContent("details.imported", value: "\(report.inserted)")
                LabeledContent("details.updated", value: "\(report.updated)")
                LabeledContent(
                    "details.alreadyImported",
                    value: "\(report.alreadyImported)"
                )
                LabeledContent(
                    "details.skipped",
                    value: "\(report.skippedCount)"
                )
                ForEach(SkipReason.allCases, id: \.self) { reason in
                    if let count = report.skipped[reason], count > 0 {
                        LabeledContent(
                            NSLocalizedString(
                                reason.description,
                                comment: "Skipped reading reason"
                            ),
                            value: "\(count)"
                        )
                    }
                }
            }
        }
    }
}

private struct InformationView: View {
    var body: some View {
        List {
            Section {
                Text("warning.secondaryRecord")
            } header: {
                Text("warning.title")
            }
            Section("about.privacy") {
                privacyPoint(
                    "key.horizontal",
                    title: "about.credentials.title",
                    description: "about.credentials.detail"
                )
                privacyPoint(
                    "chart.bar.xaxis",
                    title: "about.analytics.title",
                    description: "about.analytics.detail"
                )
                privacyPoint(
                    "heart.text.square",
                    title: "about.healthData.title",
                    description: "about.healthData.detail"
                )
                privacyPoint(
                    "arrow.clockwise",
                    title: "about.limitations.title",
                    description: "about.limitations.detail"
                )
            }
            Section {
                LabeledContent(
                    "about.version",
                    value: Bundle.main.infoDictionary?[
                        "CFBundleShortVersionString"
                    ] as? String ?? "—"
                )
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("tab.information")
        .navigationBarTitleDisplayMode(.large)
    }

    private func privacyPoint(
        _ systemImage: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.blue)
        }
    }
}

extension View {
    func privacyCovered() -> some View {
        modifier(PrivacyCover())
    }

    func bottomActionLayout() -> some View {
        padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea(
                    edges: .bottom
                )
            )
    }
}

private struct PrivacyCover: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if scenePhase != .active {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                Label("app.name", systemImage: "lock.shield")
                    .font(.title2).foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    fileprivate func groupedCard() -> some View {
        background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct ActivityFeedbackModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content
            .alert(
                "common.actionNeeded",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.dismissError() } }
                )
            ) {
                Button("common.dismiss", role: .cancel) { model.dismissError() }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}

private func profileName(_ connection: Connection) -> String {
    connection.displayName ?? String(localized: "profile.unnamed")
}

@MainActor
private func selectedProfileName(_ model: AppModel) -> String {
    if let connection = model.selectedConnection {
        return profileName(connection)
    }
    return String(
        localized: model.selectedPatientID == nil
            ? "checklist.profile.inactive" : "profile.unavailable"
    )
}

private func glucoseLabel(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0)))) \(GlucoseUnit.mgDl.rawValue)"
}

private func dateLabel(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .standard)
        ?? String(localized: "common.never")
}
