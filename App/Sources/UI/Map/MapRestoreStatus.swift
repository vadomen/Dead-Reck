import Foundation
import SwiftUI

/// The map's "Restored · 12 min ago · not yet confirmed" line (UX-20): shown
/// for as long as the restored estimate is unconfirmed, hidden on
/// confirmation, rejection or without a restore. The age is the saved
/// estimate's age when the run started (fixed), not a ticking clock.
enum RestoreStatus {
    /// "<1 min ago", "n min ago" (under 60 min), "n h ago" (whole hours, rounded down).
    static func age(seconds: Double) -> String {
        let minutes = seconds.isFinite ? max(0, Int((seconds / 60).rounded(.down))) : 0
        if minutes < 1 { return String(localized: "<1 min ago") }
        if minutes < 60 { return String(localized: "\(minutes) min ago") }
        return String(localized: "\(minutes / 60) h ago")
    }

    /// The line, or nil unless a restored estimate is still unconfirmed.
    static func line(_ restore: RestoreDisplay?) -> String? {
        guard let restore, restore.status == .unconfirmed else { return nil }
        let age = age(seconds: restore.ageAtStartS)
        return String(localized: "Restored \u{00B7} \(age) \u{00B7} not yet confirmed")
    }
}

/// Its own view, so only it observes the feed's `restore` (written a few
/// times per run). Same capsule as `PositionStatusLine`.
struct RestoreStatusLine: View {
    var feed: NavigationFeed

    var body: some View {
        RestoreStatusLabel(text: RestoreStatus.line(feed.restore))
    }
}

/// Plain-values presentation, for previews.
struct RestoreStatusLabel: View {
    var text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .hudSurface(Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
                .transition(.opacity)
        }
    }
}

#Preview("Restored") {
    RestoreStatusLabel(text: RestoreStatus.line(RestoreDisplay(status: .unconfirmed, ageAtStartS: 720))).padding()
}

#Preview("Restored, large type") {
    RestoreStatusLabel(text: RestoreStatus.line(RestoreDisplay(status: .unconfirmed, ageAtStartS: 3 * 3600)))
        .padding()
        .dynamicTypeSize(.accessibility2)
}
