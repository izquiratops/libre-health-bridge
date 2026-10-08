import SwiftUI

struct LoginView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
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
            Section {
                Label("login.welcome", systemImage: "heart.text.square")
                    .font(.headline)
                    .foregroundStyle(.pink)
                Text("login.explanation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image("Bridge")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 140)
                    .accessibilityLabel("LibreLinkUp readings sync to Apple Health")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: submitLogin) {
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

    private func submitLogin() {
        Task {
            if await model.login(email: email, password: password) {
                email = ""
                password = ""
                dismiss()
            }
        }
    }
}
