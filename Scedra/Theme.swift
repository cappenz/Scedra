import SwiftUI
import UIKit

enum ScedraThemeID: String, CaseIterable, Identifiable {
    case lavender
    case blush
    case sage
    case midnight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lavender: ScedraString("Lavender")
        case .blush: ScedraString("Blush")
        case .sage: ScedraString("Sage")
        case .midnight: ScedraString("Midnight")
        }
    }

    var prefersDark: Bool { self == .midnight }

    var preferredColorScheme: ColorScheme { prefersDark ? .dark : .light }
}

enum ScedraThemeStore {
    static let key = "scedra.theme"

    static func id(from defaults: UserDefaults = .standard) -> ScedraThemeID {
        ScedraThemeID(rawValue: defaults.string(forKey: key) ?? "") ?? .lavender
    }

    static func set(_ id: ScedraThemeID, in defaults: UserDefaults = .standard) {
        defaults.set(id.rawValue, forKey: key)
    }
}

struct ScedraPalette {
    let purple: Color
    let deepPurple: Color
    let lavender: Color
    let blush: Color
    let mist: Color
    let card: Color
    let conflict: Color
    let wash: Color
    /// Look-row chip. Midnight stays a dark ink so it still reads as the dark option.
    let swatch: Color
}

enum ScedraTheme {
    static var selectedID: ScedraThemeID { ScedraThemeStore.id() }

    static func palette(for id: ScedraThemeID) -> ScedraPalette {
        switch id {
        case .lavender:
            ScedraPalette(
                purple: Color(red: 0.45, green: 0.32, blue: 0.75),
                deepPurple: Color(red: 0.33, green: 0.22, blue: 0.58),
                lavender: Color(red: 0.80, green: 0.74, blue: 0.94),
                blush: Color(red: 0.97, green: 0.94, blue: 1.0),
                mist: Color(red: 0.93, green: 0.89, blue: 0.98),
                card: .white,
                conflict: Color(red: 0.86, green: 0.48, blue: 0.16),
                wash: Color(red: 0.90, green: 0.86, blue: 0.97),
                swatch: Color(red: 0.45, green: 0.32, blue: 0.75)
            )
        case .blush:
            ScedraPalette(
                purple: Color(red: 0.72, green: 0.34, blue: 0.46),
                deepPurple: Color(red: 0.52, green: 0.22, blue: 0.32),
                lavender: Color(red: 0.96, green: 0.78, blue: 0.82),
                blush: Color(red: 1.0, green: 0.95, blue: 0.94),
                mist: Color(red: 0.98, green: 0.90, blue: 0.90),
                card: .white,
                conflict: Color(red: 0.86, green: 0.48, blue: 0.16),
                wash: Color(red: 0.97, green: 0.86, blue: 0.86),
                swatch: Color(red: 0.72, green: 0.34, blue: 0.46)
            )
        case .sage:
            ScedraPalette(
                purple: Color(red: 0.34, green: 0.50, blue: 0.42),
                deepPurple: Color(red: 0.22, green: 0.38, blue: 0.32),
                lavender: Color(red: 0.78, green: 0.88, blue: 0.80),
                blush: Color(red: 0.95, green: 0.97, blue: 0.94),
                mist: Color(red: 0.88, green: 0.93, blue: 0.88),
                card: .white,
                conflict: Color(red: 0.86, green: 0.48, blue: 0.16),
                wash: Color(red: 0.84, green: 0.91, blue: 0.84),
                swatch: Color(red: 0.34, green: 0.50, blue: 0.42)
            )
        case .midnight:
            ScedraPalette(
                purple: Color(red: 0.72, green: 0.64, blue: 0.94),
                deepPurple: Color(red: 0.93, green: 0.91, blue: 0.98),
                lavender: Color(red: 0.30, green: 0.26, blue: 0.44),
                blush: Color(red: 0.20, green: 0.17, blue: 0.28),
                mist: Color(red: 0.18, green: 0.16, blue: 0.26),
                card: Color(red: 0.14, green: 0.12, blue: 0.20),
                conflict: Color(red: 0.95, green: 0.62, blue: 0.32),
                wash: Color(red: 0.06, green: 0.05, blue: 0.10),
                swatch: Color(red: 0.20, green: 0.16, blue: 0.32)
            )
        }
    }

    static var current: ScedraPalette { palette(for: selectedID) }

    static var purple: Color { current.purple }
    static var deepPurple: Color { current.deepPurple }
    static var lavender: Color { current.lavender }
    static var blush: Color { current.blush }
    static var mist: Color { current.mist }
    static var card: Color { current.card }
    static var conflict: Color { current.conflict }

    static var background: LinearGradient {
        LinearGradient(
            colors: [blush, mist, current.wash],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Rebuilds a screen when the stored palette changes so `ScedraTheme` colors refresh.
private struct ScedraUsesSelectedTheme: ViewModifier {
    @AppStorage(ScedraThemeStore.key) private var themeID = ScedraThemeID.lavender.rawValue

    func body(content: Content) -> some View {
        content
            .id(themeID)
            .preferredColorScheme((ScedraThemeID(rawValue: themeID) ?? .lavender).preferredColorScheme)
    }
}

extension View {
    func scedraUsesSelectedTheme() -> some View {
        modifier(ScedraUsesSelectedTheme())
    }
}

/// Brand title + Settings gear in the page, not the system toolbar.
/// Putting these in `toolbar` on iOS 26 collapses the gear into a corner ⋯ menu.
struct ScedraScreenHeader: View {
    var title: LocalizedStringKey
    var onSettings: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(ScedraTheme.purple)
            Spacer(minLength: 12)
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(ScedraTheme.purple)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ScedraString("Settings"))
        }
    }
}

struct ScedraCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(ScedraTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(
                color: ScedraTheme.selectedID.prefersDark
                    ? Color.black.opacity(0.45)
                    : ScedraTheme.purple.opacity(0.12),
                radius: 18,
                y: 8
            )
    }
}

extension View {
    func scedraCard() -> some View {
        modifier(ScedraCard())
    }

    /// Scroll or tap away to drop the keyboard. The tap does not cancel button
    /// hits, and it ignores `UITextField` / `UITextView` so the cursor still moves.
    func scedraDismissesKeyboard<Field: Hashable>(_ focusedField: FocusState<Field?>.Binding) -> some View {
        scrollDismissesKeyboard(.immediately)
            .background {
                ScedraKeyboardDismissTap {
                    focusedField.wrappedValue = nil
                    ScedraKeyboard.resign()
                }
            }
    }
}

enum ScedraKeyboard {
    static func resign() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

/// Window-level tap that resigns the keyboard without eating Confirm / Navigate.
private struct ScedraKeyboardDismissTap: UIViewRepresentable {
    var onDismiss: () -> Void

    func makeUIView(context: Context) -> ScedraKeyboardDismissView {
        let view = ScedraKeyboardDismissView()
        view.onDismiss = onDismiss
        return view
    }

    func updateUIView(_ uiView: ScedraKeyboardDismissView, context: Context) {
        uiView.onDismiss = onDismiss
    }
}

private final class ScedraKeyboardDismissView: UIView, UIGestureRecognizerDelegate {
    var onDismiss: (() -> Void)?
    private var recognizer: UITapGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        recognizer.flatMap { $0.view?.removeGestureRecognizer($0) }
        recognizer = nil
        guard let window else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizer = tap
    }

    @objc private func handleTap() {
        onDismiss?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }
}
