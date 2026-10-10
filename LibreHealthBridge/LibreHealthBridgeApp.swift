import SwiftUI

@main
struct LibreHealthBridgeApp: App {
    #if DEBUG && targetEnvironment(simulator)
    @State private var launch = SimulatorScenarios.launch()
    #else
    @State private var model = AppModel()
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                ContentView(model: launch.model)
                #else
                ContentView(model: model)
                #endif
            }
            .privacyCovered()
            .task {
                #if DEBUG && targetEnvironment(simulator)
                await launch.restore()
                #else
                await model.restore()
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    #if DEBUG && targetEnvironment(simulator)
                    launch.model.refreshHealthAccess()
                    #else
                    model.refreshHealthAccess()
                    #endif
                }
            }
        }
    }
}
