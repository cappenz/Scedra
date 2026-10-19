import SwiftUI

/// Which Capture control the add-event coach should pulse. Taps stay on the real UI.
enum OnboardingCaptureHighlight: Equatable {
    case modes
    case voice
    case photo
    case typeField
}

enum OnboardingCaptureCoach {
    /// After a mode is picked, always point at that mode's control — leftover
    /// composer text must not skip Voice / Photo / Type.
    static func highlight(
        phase: OnboardingEventWalkthrough?,
        mode: CaptureMode
    ) -> OnboardingCaptureHighlight? {
        switch phase {
        case .captureModes:
            return .modes
        case .captureInput:
            switch mode {
            case .voice: return .voice
            case .photo: return .photo
            case .type: return .typeField
            }
        case .review, .saved, nil:
            return nil
        }
    }
}

struct OnboardingCoachSkipChip: View {
    var onSkip: () -> Void

    var body: some View {
        Button("Skip", action: onSkip)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ScedraTheme.purple)
            .buttonStyle(.plain)
    }
}

/// Short bouncing arrow. Hit-testing is off so the control underneath stays tappable.
struct OnboardingCoachArrow: View {
    var size: CGFloat = 14

    @State private var bounce = false

    var body: some View {
        Image(systemName: "arrowtriangle.down.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(ScedraTheme.purple)
            .shadow(color: ScedraTheme.purple.opacity(0.45), radius: 4, y: 1)
            .offset(y: bounce ? 5 : 0)
            .onAppear { bounce = true }
            .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: bounce)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

struct OnboardingCoachPulse: ViewModifier {
    var isActive: Bool
    var cornerRadius: CGFloat?
    var showsArrow: Bool
    var arrowSize: CGFloat

    @State private var pulse = false

    func body(content: Content) -> some View {
        VStack(spacing: 4) {
            if isActive && showsArrow {
                OnboardingCoachArrow(size: arrowSize)
            }
            content
                .background {
                    if isActive {
                        glowFill
                    }
                }
                .overlay {
                    if isActive {
                        glowStroke
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .onAppear { restartPulse(isActive) }
        .onChange(of: isActive) { _, active in
            restartPulse(active)
        }
        .animation(
            isActive ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true) : .default,
            value: pulse
        )
    }

    @ViewBuilder
    private var glowFill: some View {
        if let cornerRadius {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(ScedraTheme.purple.opacity(pulse ? 0.1 : 0.28))
                .padding(-10)
                .allowsHitTesting(false)
        } else {
            Capsule()
                .fill(ScedraTheme.purple.opacity(pulse ? 0.1 : 0.28))
                .padding(-10)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var glowStroke: some View {
        if let cornerRadius {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(ScedraTheme.purple, lineWidth: pulse ? 2.5 : 4)
                .padding(-6)
                .shadow(color: ScedraTheme.purple.opacity(pulse ? 0.3 : 0.85), radius: pulse ? 3 : 10)
                .allowsHitTesting(false)
        } else {
            Capsule()
                .stroke(ScedraTheme.purple, lineWidth: pulse ? 2.5 : 4)
                .padding(-6)
                .shadow(color: ScedraTheme.purple.opacity(pulse ? 0.3 : 0.85), radius: pulse ? 3 : 10)
                .allowsHitTesting(false)
        }
    }

    private func restartPulse(_ active: Bool) {
        pulse = false
        guard active else { return }
        Task { @MainActor in
            pulse = true
        }
    }
}

extension View {
    func onboardingCoachPulse(
        isActive: Bool,
        cornerRadius: CGFloat? = nil,
        showsArrow: Bool = false,
        arrowSize: CGFloat = 14
    ) -> some View {
        modifier(
            OnboardingCoachPulse(
                isActive: isActive,
                cornerRadius: cornerRadius,
                showsArrow: showsArrow,
                arrowSize: arrowSize
            )
        )
    }
}
