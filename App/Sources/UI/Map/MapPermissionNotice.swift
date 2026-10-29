import SwiftUI

/// The map's explanation of a refused Location permission (R-QA42-1, prompt 43):
/// one line in the bottom stack with a button that opens the app's page in iOS
/// Settings. Pure, so a test checks the choice and the texts without a view.
///
/// - Location refused: the map cannot show the phone's position; navigation by
///   OBD still works but needs a starting point from the driver (`note`).
/// - Motion & Fitness refused: no line (R81.1-1). That permission gates only
///   the altimeter; the dead-reckoning engine reads no barometer, so navigation
///   works and "Finding your position…" stays truthful.
/// - Nothing refused: nil, so the line is gone after the permission is granted again.
enum MapPermissionNotice: Equatable, Sendable {
    case locationDenied

    /// nil while nothing is refused or during the demo (its sensors are not the phone's).
    static func make(_ access: SensorAccess, demo: Bool) -> MapPermissionNotice? {
        guard !demo else { return nil }
        return access.locationDenied ? .locationDenied : nil
    }

    var message: String {
        switch self {
        case .locationDenied: String(localized: "No location access — the map can't show where you are")
        }
    }

    /// The button's text, after the message (iOS Settings, not the app's own).
    static var buttonTitle: String {
        String(localized: "Open iOS Settings (map line)", comment: "Short button at the end of the map's permission line; opens the app's page in iOS Settings. uk «Параметри» (Apple's name for the iOS Settings app).")
    }

    /// One short extra line (normal text sizes only): what still works without Location.
    var note: String? {
        switch self {
        case .locationDenied: String(localized: "OBD navigation needs a starting point — place a pin on the map")
        }
    }

    var accessibilityLabel: String { "\(message), \(Self.buttonTitle)" }
}

struct MapPermissionLine: View {
    var notice: MapPermissionNotice
    var showsNote = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                (Text(notice.message) + Text(verbatim: " · ") + Text(MapPermissionNotice.buttonTitle).bold().underline())
                    .font(.subheadline.weight(.semibold))
                if showsNote, let note = notice.note {
                    Text(note).font(.footnote).foregroundStyle(HUDColors.muted)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hudSurface(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tone.bad.color, lineWidth: 2))
        }
        .buttonStyle(.plain)
        // Wraps in full, never grows past AX2 (the stack's rule).
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityLabel(notice.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Location denied") {
    MapPermissionLine(notice: .locationDenied).padding()
}

#Preview("Location denied, large type") {
    MapPermissionLine(notice: .locationDenied, showsNote: false).padding().dynamicTypeSize(.accessibility2)
}
