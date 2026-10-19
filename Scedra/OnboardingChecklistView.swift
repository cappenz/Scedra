import SwiftUI

struct OnboardingChecklistView: View {
    @Bindable var guide: OnboardingGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Get set up")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(ScedraTheme.deepPurple)
                Text("\(guide.progress.completedCount)/3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ScedraTheme.purple)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                Button("Dismiss") {
                    guide.dismissAll()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(ScedraTheme.purple)
            }

            ForEach(OnboardingStep.allCases) { step in
                stepRow(step)
            }

            if guide.showsYoureSet {
                Text("You're set")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ScedraTheme.purple)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: guide.progress)
        .animation(.easeInOut(duration: 0.28), value: guide.showsYoureSet)
        .scedraCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ScedraString("Get set up"))
        .accessibilityValue("\(guide.progress.completedCount)/3")
    }

    private func stepRow(_ step: OnboardingStep) -> some View {
        let done = guide.progress.isDone(step)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? ScedraTheme.purple : ScedraTheme.purple.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(step))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ScedraTheme.deepPurple)
                    Text(detail(step, done: done))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !done {
                    Button("Skip") {
                        guide.skip(step)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ScedraTheme.purple)
                }
            }

            if !done {
                Button {
                    guide.start(step)
                } label: {
                    Text(actionTitle(step))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(ScedraTheme.lavender.opacity(0.7), in: Capsule())
                        .foregroundStyle(ScedraTheme.deepPurple)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
    }

    private func title(_ step: OnboardingStep) -> LocalizedStringKey {
        switch step {
        case .home: "Set home"
        case .event: "Add an event"
        case .task: "Add a task"
        }
    }

    private func detail(_ step: OnboardingStep, done: Bool) -> LocalizedStringKey {
        switch step {
        case .home:
            "Used for travel times and whether to go home between stops."
        case .event:
            done
                ? "It's on Calendar and Today."
                : "Speak, scan, or type, then Confirm. It occupies a time on Calendar."
        case .task:
            done
                ? "It's on Calendar in a free slot."
                : "Scedra places it on Calendar in a free slot. Events occupy a time; tasks get placed in free time."
        }
    }

    private func actionTitle(_ step: OnboardingStep) -> LocalizedStringKey {
        switch step {
        case .home: "Set home"
        case .event: "Capture"
        case .task: "Add task"
        }
    }
}

/// Saved-step line on Capture after Confirm. Skip hides it; controls stay tappable.
struct OnboardingCoachBanner: View {
    var message: LocalizedStringKey
    var onSkip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(ScedraTheme.deepPurple)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Skip", action: onSkip)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ScedraTheme.purple)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            ScedraTheme.lavender.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}
