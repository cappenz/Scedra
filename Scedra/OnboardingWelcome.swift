import SwiftUI

struct OnboardingWelcomeView: View {
    var onContinue: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ScedraTheme.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 22) {
                    Text("Welcome to Scedra")
                        .font(.system(size: 30, weight: .regular, design: .serif))
                        .foregroundStyle(ScedraTheme.deepPurple)

                    Text("Speak, scan, or type — Scedra puts it on Apple Calendar. Events occupy a time. Tasks get a time in a free slot.")
                        .font(.body)
                        .foregroundStyle(ScedraTheme.deepPurple.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    Button(action: onContinue) {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(ScedraTheme.purple, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
            }
            .scedraUsesSelectedTheme()
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}
