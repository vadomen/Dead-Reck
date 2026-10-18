import SwiftUI

/// Filled accent button whose label stays readable in both appearances.
/// The dark accent is bright (so the selected tab reads on black), which
/// makes white labels only ~2.2:1; `AccentForeground` is white in light and
/// black in dark (>= 4.5:1 on the accent in each mode). A disabled button
/// keeps the system's grey fill, so it gets a grey label, not the accent one.
extension View {
    func prominentButton() -> some View {
        modifier(ProminentButtonLabel())
    }
}

private struct ProminentButtonLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .foregroundStyle(isEnabled ? Color("AccentForeground") : Color.secondary)
    }
}
