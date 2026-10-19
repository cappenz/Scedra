import SwiftUI

struct OnboardingSettingsEntry: View {
    @Bindable var guide: OnboardingGuide
    var onOpen: () -> Void

    var body: some View {
        Button {
            guide.reopenFromSettings()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Setup guide")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ScedraTheme.deepPurple)
                Text("Home, a first event, and a first task.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scedraCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ScedraString("Setup guide"))
        .accessibilityHint(ScedraString("Home, a first event, and a first task."))
    }
}
