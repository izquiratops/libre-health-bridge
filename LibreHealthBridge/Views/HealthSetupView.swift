import BridgeCore
import SwiftUI
import UIKit

struct HealthSetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingProfile: Connection?
    @State private var showProfileSwitch = false
    @State private var showHealthOpenFailure = false

    private var readingStatusText: String {
        if model.canConfirmPreview && model.isVerified { return "reading.confirmed" }
        if model.selectedConnection == nil { return "reading.chooseProfileFirst" }
        if model.snapshot != nil && !model.isPreviewCurrent {
            return "reading.refreshRequired"
        }
        return model.canConfirmPreview ? "reading.confirmPrompt" : "reading.noLatest"
    }

    var body: some View {
        Form {
            profileSection
            readingValidationSection
            healthAccessSection
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: startSync) {
                Text("health.setup.sync")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStartHealthSync)
            .accessibilityIdentifier("health.setup.sync")
            .bottomActionLayout()
        }
        .disabled(model.isBusy)
        .privacySensitive()
        .navigationTitle("health.setup.modalTitle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("common.close", systemImage: "xmark") { dismiss() }
                    .disabled(model.isBusy)
            }
        }
        .modifier(ActivityFeedbackModifier(model: model))
        .onAppear {
            model.refreshHealthAccess()
            if model.isHealthSyncActive { dismiss() }
        }
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

    private var readingValidationSection: some View {
        Section {
            statusLine(
                readingStatusText,
                icon: model.isVerified && model.canConfirmPreview ? "clock.fill" : "clock",
                complete: model.isVerified && model.canConfirmPreview
            )
            if model.canConfirmPreview, let preview = model.snapshot?.preview,
                let value = preview.valueMgDl, let time = preview.timestamp
            {
                LabeledContent("reading.latest", value: glucoseLabel(value))
                LabeledContent("reading.measured", value: dateLabel(time))
            }
            if model.selectedConnection != nil {
                Toggle("reading.confirm", isOn: Binding(
                    get: { model.isVerified },
                    set: { confirmed in
                        Task {
                            if confirmed {
                                _ = await model.confirmPreview()
                            } else {
                                _ = await model.revokePreviewConfirmation()
                            }
                        }
                    }
                ))
                .disabled(!model.canConfirmPreview && !model.isVerified)
                .accessibilityIdentifier("health.setup.confirm")
                Button("reading.refresh") { Task { await model.refresh() } }
                .accessibilityIdentifier("health.setup.refresh")
            }
        } header: {
            Text("reading.title")
        } footer: {
            Text("reading.validationDetail")
        }
    }

    private var healthAccessSection: some View {
        Section {
            statusLine(
                model.healthAccess.rawValue,
                icon: model.healthAccess == .authorized ? "heart.fill" : "heart",
                complete: model.healthAccess == .authorized
            )
            if model.session?.syncPaused == true && model.session?.lastSync != nil {
                Text("health.sync.paused").foregroundStyle(.secondary)
            }
            if model.healthAccess == .denied {
                Text("health.setup.enableWrites").foregroundStyle(.secondary)
            }
            if model.healthAccess != .authorized
                && model.healthAccess != .unavailable
            {
                Button(
                    model.healthAccess == .denied
                        ? "health.setup.openHealth"
                        : "health.setup.requestPermission",
                    action: handleHealthAccessAction
                )
                .disabled(!model.isVerified)
                .alert("health.setup.openHealthFailed", isPresented: $showHealthOpenFailure) {
                    Button("common.close", role: .cancel) {}
                } message: {
                    Text("health.setup.enableWrites")
                }
            }
        } header: {
            Text("health.setup.title")
        } footer: {
            Text("health.setup.explanation")
        }
    }

    private func handleHealthAccessAction() {
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

    private func startSync() {
        Task {
            // The model rechecks eligibility, refetches, and checks permission before writing.
            let outcome = await model.sync(starting: true)
            if outcome == .success {
                dismiss()
            }
        }
    }

    private func statusLine(_ title: String, icon: String, complete: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .foregroundStyle(.primary)
        }
    }

    private var profileSection: some View {
        Section {
            profilePicker

            if model.selectedConnection == nil {
                Text(model.connections.isEmpty
                    ? "profile.none"
                    : model.selectedPatientID == nil
                        ? "profile.selectPrompt" : "health.sync.profileMissing")
                    .foregroundStyle(.secondary)
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

    private var profilePicker: some View {
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
            HStack(spacing: 12) {
                Image(systemName: model.selectedConnection == nil
                    ? "person.crop.circle" : "person.crop.circle.fill")
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
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
            .foregroundStyle(.primary)
        }
        .tint(Color.primary)
        .disabled(model.connections.isEmpty)
        .accessibilityLabel(Text("profile.choose"))
        .accessibilityValue(selectedProfileName(model))
        .accessibilityIdentifier("profile.select")
    }
}
