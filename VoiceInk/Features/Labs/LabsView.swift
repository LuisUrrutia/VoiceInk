import SwiftUI

struct LabsView: View {
    var features: [LabsFeature] = LabsFeature.all

    var body: some View {
        Form {
            Section {
                ForEach(features) { feature in
                    LabsFeatureRow(feature: feature)
                }
            } header: {
                Text("Unfinished features")
            } footer: {
                Text("Try unfinished features. They may change or break. Each one is off until you turn it on, and switches apply immediately.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(AppSettingsFormStyle())
    }
}

private struct LabsFeatureRow: View {
    let feature: LabsFeature
    @AppStorage private var isOn: Bool

    init(feature: LabsFeature) {
        self.feature = feature
        _isOn = AppStorage(wrappedValue: false, feature.defaultsKey)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                Text(feature.summary)
                    .settingsDescription()
            }
        }
        .accessibilityLabel(Text(feature.title))
        .accessibilityHint(Text(feature.summary))
        .accessibilityIdentifier("labs.\(feature.id)")
    }
}
