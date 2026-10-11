import SwiftUI
import UIKit

struct HomeView: View {
    @Bindable var model: AppModel
    let openLogin: () -> Void
    let openSetup: () -> Void
    @State private var showLogout = false
    @State private var showHomeSyncSuccess = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var readyForSync: Bool { model.isHealthSyncActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryCard
                NavigationLink {
                    AutomaticSyncView(model: model)
                } label: {
                    Label("automatic.title", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                .accessibilityIdentifier("automatic.open")
                .groupedCard()

                if model.isSignedIn {
                    connectionSection
                    accountSection
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
        .alert("account.logOutConfirm", isPresented: $showLogout) {
            Button("account.logOut", role: .destructive) {
                Task { await model.logout() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("account.logOutExplanation")
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("home.connection")
            VStack(spacing: 0) {
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
                    value: LocalizedStringKey(model.healthSyncStatus)
                )
                if readyForSync {
                    insetDivider
                    Button("health.sync.stop", role: .destructive) {
                        Task { _ = await model.stopHealthSync() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("health.stop")
                }
            }
            .groupedCard()
        }
    }

    private var accountSection: some View {
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

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryStatusDetails
            summaryPrimaryAction
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

    private var summaryStatusDetails: some View {
        Group {
            Label("home.summary", systemImage: "heart.text.square.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.pink)
            Text(
                model.isSignedIn
                    ? LocalizedStringKey(model.healthSyncStatus)
                    : "checklist.account.inactive"
            )
            .font(.title2.weight(.bold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                model.isSignedIn
                    ? (readyForSync
                        ? "sync.explanation"
                        : model.session?.syncPaused == true
                            ? "health.sync.resumeDetail" : "checklist.sync.setupDetail")
                    : "checklist.intro"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if model.restoration == .retryableFailure && !model.isSignedIn {
                Button("profile.refresh") { Task { await model.restore() } }
            }
            if let lastSync = model.session?.lastSync {
                VStack(alignment: .leading, spacing: 4) {
                    Text("sync.lastCompleted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dateLabel(lastSync))
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .privacySensitive()
            }
        }
    }

    private var summaryPrimaryAction: some View {
        Group {
            Divider()
            Button(action: handlePrimaryAction) {
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
    }

    private func handlePrimaryAction() {
        guard model.isSignedIn else {
            openLogin()
            return
        }
        Task {
            switch await model.primaryHealthAction() {
            case .openSetup: openSetup()
            case .syncSucceeded: showHomeSyncSuccess = true
            case .stay: break
            }
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
