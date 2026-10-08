import BridgeCore
import SwiftUI
import UIKit

// Layout
extension View {
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

    func groupedCard() -> some View {
        background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

// Privacy
extension View {
    func privacyCovered() -> some View {
        modifier(PrivacyCover())
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

// Activity and error feedback
struct ActivityFeedbackModifier: ViewModifier {
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

// Formatting
func profileName(_ connection: Connection) -> String {
    connection.displayName ?? String(localized: "profile.unnamed")
}

@MainActor
func selectedProfileName(_ model: AppModel) -> String {
    if let connection = model.selectedConnection {
        return profileName(connection)
    }
    return String(
        localized: model.selectedPatientID == nil
            ? "checklist.profile.inactive" : "profile.unavailable"
    )
}

func glucoseLabel(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0)))) \(GlucoseUnit.mgDl.rawValue)"
}

func dateLabel(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .standard)
        ?? String(localized: "common.never")
}
