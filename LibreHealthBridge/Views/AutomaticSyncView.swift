import SwiftUI

struct AutomaticSyncView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("automatic.intro")
                Text("automatic.cost")
                Text("automatic.timing")
                Text("automatic.locked")
                Text("automatic.unofficial")
                Text("automatic.safety")
            } header: { Text("automatic.title") }

            if model.ownership == .owned {
                Section {
                    Toggle("automatic.enable", isOn: Binding(
                        get: { model.session?.automaticEnabled == true },
                        set: { value in Task { await model.setAutomaticEnabled(value) } }
                    ))
                    .disabled(model.isBusy || (model.session?.automaticEnabled != true && !model.canEnableAutomatic))
                    .accessibilityIdentifier("automatic.enable")
                    Picker("automatic.interval", selection: Binding(
                        get: { model.session?.automaticInterval ?? 30 },
                        set: { model.setAutomaticInterval($0) }
                    )) {
                        Text("automatic.15").tag(15)
                        Text("automatic.30").tag(30)
                        Text("automatic.60").tag(60)
                    }
                    .disabled(model.session?.automaticEnabled != true || model.isBusy)
                    .accessibilityIdentifier("automatic.interval")
                } footer: {
                    Text("automatic.locked")
                }
            } else {
                Section {
                    if let price = model.premiumPrice {
                        Button {
                            Task { await model.buyPremium() }
                        } label: {
                            Text(String(format: NSLocalizedString("automatic.buy", comment: "Purchase button"), price))
                        }
                        .disabled(model.isPremiumBusy)
                        .accessibilityIdentifier("automatic.buy")
                    } else {
                        Text("automatic.productUnavailable")
                    }
                    Button("automatic.restore") { Task { await model.restorePremium() } }
                        .disabled(model.isPremiumBusy)
                        .accessibilityIdentifier("automatic.restore")
                }
            }
            Section {
                Text(LocalizedStringKey(model.automaticStatus))
                    .accessibilityIdentifier("automatic.status")
                if model.ownership == .owned && !model.isHealthSyncActive {
                    Text("automatic.setupRequired")
                }
                if let message = model.automaticMessage {
                    Text(LocalizedStringKey(message))
                }
            } header: { Text("automatic.statusTitle") }
        }
        .navigationTitle("automatic.title")
        .onAppear { model.refreshHealthAccess() }
    }
}
