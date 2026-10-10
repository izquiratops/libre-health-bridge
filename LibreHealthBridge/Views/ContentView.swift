import SwiftUI

enum AppTab: Hashable {
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
