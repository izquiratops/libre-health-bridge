import SwiftUI
import UIKit

#if DEBUG && targetEnvironment(simulator)
@MainActor private enum SimulatorRuntime {
    static let composition = SimulatorScenarios.launch()
}
#endif

@MainActor private enum LiveModel {
    static let instance = AppModel()
}

@main
struct LibreHealthBridgeApp: App {
    #if DEBUG && targetEnvironment(simulator)
    @State private var launch = SimulatorRuntime.composition
    #else
    @State private var model = LiveModel.instance
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundRefresh.register { task in
            #if DEBUG && targetEnvironment(simulator)
            await SimulatorRuntime.composition.model.handleBackgroundTask(task)
            #else
            await LiveModel.instance.handleBackgroundTask(task)
            #endif
        }
    }

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
                // A cold BGTask launch must not run the foreground preview restore.
                guard UIApplication.shared.applicationState == .active else { return }
                await foregroundStart()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    #if DEBUG && targetEnvironment(simulator)
                    launch.model.refreshHealthAccess()
                    #else
                    model.refreshHealthAccess()
                    #endif
                    Task { await foregroundStart() }
                }
            }
        }
    }

    private func foregroundStart() async {
        #if DEBUG && targetEnvironment(simulator)
        await launch.restore()
        await launch.model.startPremiumObservation()
        #else
        await model.restore()
        await model.startPremiumObservation()
        #endif
    }
}
