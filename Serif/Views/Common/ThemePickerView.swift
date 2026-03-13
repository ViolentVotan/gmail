import SwiftUI

struct ThemePickerView: View {
    @Bindable var appearanceManager: AppearanceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(Typography.headline)

            Picker("Appearance", selection: $appearanceManager.preference) {
                Text("System").tag(AppearanceManager.Preference.system)
                Text("Light").tag(AppearanceManager.Preference.light)
                Text("Dark").tag(AppearanceManager.Preference.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .cardStyle()
    }
}
