import SwiftUI

@main
struct LibreHealthBridgeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .privacyCovered()
            .task { await model.restore() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshHealthAccess() }
            }
        }
    }
}
