import SwiftUI

private enum AppTab: Hashable {
    case home, information
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showLogin = false
    @State private var showSetup = false
    @State private var selectedTab: AppTab = .home

    var body: some View {
        appNavigation
    }

    private var appNavigation: some View {
        #if DEBUG && targetEnvironment(simulator)
            presentedTabs.modifier(
                SimulatorLaunchRouting(
                    selectedTab: $selectedTab,
                    showLogin: $showLogin,
                    showSetup: $showSetup
                )
            )
        #else
            presentedTabs
        #endif
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(
                    model: model,
                    openLogin: { showLogin = true },
                    openSetup: { showSetup = true }
                )
            }
            .tabItem { Label("tab.home", systemImage: "heart") }
            .tag(AppTab.home)

            NavigationStack { InformationView() }
                .tabItem { Label("tab.information", systemImage: "info.circle") }
                .tag(AppTab.information)
        }
    }

    private var presentedTabs: some View {
        tabs
            .sheet(isPresented: $showLogin) {
                NavigationStack { LoginView(model: model) }
                    .privacyCovered()
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled(model.isBusy)
            }
            .sheet(isPresented: $showSetup) {
                NavigationStack { HealthSetupView(model: model) }
                    .privacyCovered()
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled(model.isBusy)
            }
    }
}

#if DEBUG && targetEnvironment(simulator)
    private struct SimulatorLaunchRouting: ViewModifier {
        @Binding var selectedTab: AppTab
        @Binding var showLogin: Bool
        @Binding var showSetup: Bool
        @State private var didRouteLaunch = false

        func body(content: Content) -> some View {
            content.onAppear(perform: routeLaunchScreen)
        }

        private func routeLaunchScreen() {
            guard !didRouteLaunch else { return }
            didRouteLaunch = true
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--ui-screen"),
                arguments.indices.contains(index + 1)
            else { return }
            switch arguments[index + 1] {
            case "home": selectedTab = .home
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
    }
#endif
