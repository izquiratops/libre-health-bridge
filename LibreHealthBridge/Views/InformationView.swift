import SwiftUI

struct InformationView: View {
    var body: some View {
        List {
            Section {
                Text("about.intro.detail")
            } header: {
                Text("about.intro.title")
            }
            Section("about.privacy") {
                privacyPoint(
                    "key.horizontal",
                    title: "about.credentials.title",
                    description: "about.credentials.detail"
                )
                privacyPoint(
                    "chart.bar.xaxis",
                    title: "about.analytics.title",
                    description: "about.analytics.detail"
                )
                privacyPoint(
                    "heart.text.square",
                    title: "about.healthData.title",
                    description: "about.healthData.detail"
                )
                privacyPoint(
                    "arrow.clockwise",
                    title: "about.limitations.title",
                    description: "about.limitations.detail"
                )
            }
            Section {
                LabeledContent(
                    "about.version",
                    value: Bundle.main.infoDictionary?[
                        "CFBundleShortVersionString"
                    ] as? String ?? "—"
                )
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("tab.information")
        .navigationBarTitleDisplayMode(.large)
    }

    private func privacyPoint(
        _ systemImage: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.blue)
        }
    }
}
