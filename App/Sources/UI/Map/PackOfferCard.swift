import SwiftUI

/// Wording of the at-a-stop offer card (UX-8 (2), compact form R68.1-3).
enum PackOfferText {
    /// The one line: what is missing and what it costs.
    static func summary(sizeBytes: Int64, locale: Locale = .current) -> String {
        String(localized: "No road map here · \(MapsText.size(sizeBytes, locale: locale))")
    }
    /// The same line with the region, used when it fits on one line.
    static func summary(title: String, sizeBytes: Int64, locale: Locale = .current) -> String {
        String(localized: "No road map here · \(MapsText.size(sizeBytes, locale: locale)) · \(title)")
    }
    /// B4: the run has the national pack only.
    static func summary(sizeBytes: Int64, context: PackOfferMonitor.Offer.Context, locale: Locale = .current) -> String {
        switch context {
        case .noRoadMap: summary(sizeBytes: sizeBytes, locale: locale)
        case .onlyMainRoads: String(localized: "Only main roads here · \(MapsText.size(sizeBytes, locale: locale))")
        }
    }
    static func summary(
        title: String, sizeBytes: Int64, context: PackOfferMonitor.Offer.Context, locale: Locale = .current
    ) -> String {
        switch context {
        case .noRoadMap: summary(title: title, sizeBytes: sizeBytes, locale: locale)
        case .onlyMainRoads:
            String(localized: "Only main roads here · \(MapsText.size(sizeBytes, locale: locale)) · \(title)")
        }
    }
    static let download = String(localized: "Download")
    /// The primary action's label: the region is named where the line does not
    /// carry the cost of the missing map (B4: "Download <region>").
    static func downloadLabel(title: String, context: PackOfferMonitor.Offer.Context) -> String {
        context == .onlyMainRoads ? String(localized: "Download \(title)") : download
    }
    static let notNow = String(localized: "Not now")
    static let never = String(localized: "Never")
}

/// The three answers to the offer, one wiring for the card and for the roads
/// banner that hosts the offer (R75.1-4): both reach the same monitor paths.
@MainActor
struct PackOfferActions {
    var download: () -> Void
    var notNow: () -> Void
    var never: () -> Void

    init(monitor: PackOfferMonitor) {
        download = { monitor.download() }
        notNow = { monitor.notNow() }
        never = { monitor.never() }
    }
}

/// The card wired to the monitor. Its own view, so only it observes `offer`.
struct PackOfferCard: View {
    var monitor: PackOfferMonitor

    var body: some View {
        Group {
            if let offer = shown {
                let actions = PackOfferActions(monitor: monitor)
                PackOfferCardView(
                    offer: offer, onDownload: actions.download, onNotNow: actions.notNow, onNever: actions.never)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shown)
    }

    private var shown: PackOfferMonitor.Offer? { Self.current(for: monitor) }

    /// The offer on screen: the monitor's, or the DEBUG fake. The map reads it
    /// to lift the car out from under the card.
    static func current(for monitor: PackOfferMonitor) -> PackOfferMonitor.Offer? {
        #if DEBUG
        // `-uiFakeOffer 1`: a synthetic offer (screenshots; no real region).
        // 2: the run has only the national pack ("Only main roads here").
        let fake = UserDefaults.standard.integer(forKey: "uiFakeOffer")
        if fake > 0 {
            return PackOfferMonitor.Offer(
                name: "zz-01", title: "Region A", sizeBytes: 35_000_000,
                context: fake == 2 ? .onlyMainRoads : .noRoadMap)
        }
        #endif
        return monitor.offer
    }
}

/// Plain values, for previews. Non-modal: it sits above the map controls and
/// sits in the bottom-left zone, left of the rail, and never covers the HUD card (top).
struct PackOfferCardView: View {
    let offer: PackOfferMonitor.Offer
    var onDownload: () -> Void = {}
    var onNotNow: () -> Void = {}
    var onNever: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One line; the region goes on a second line only when it does not fit.
            ViewThatFits(in: .horizontal) {
                if offer.context == .onlyMainRoads {
                    // The region is the button's label; the line says what is missing.
                    Text(PackOfferText.summary(sizeBytes: offer.sizeBytes, context: offer.context))
                        .font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(PackOfferText.summary(title: offer.title, sizeBytes: offer.sizeBytes, context: offer.context))
                        .font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(PackOfferText.summary(sizeBytes: offer.sizeBytes, context: offer.context)).font(.headline)
                    if offer.context == .noRoadMap {
                        Text(offer.title).font(.subheadline).foregroundStyle(HUDColors.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // Three actions in one row. Where they do not fit at their natural width
            // (Ukrainian "Завантажити" beside "Не зараз" and "Ніколи" on a 375 pt
            // phone), Download takes its own row above the two answers; in the
            // accessibility sizes all three stack.
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { download(wraps: true); answers(stacked: true) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { download(wraps: false); answers(stacked: false) }
                    VStack(spacing: 8) { download(wraps: true); HStack(spacing: 8) { answers(stacked: true) } }
                }
            }
        }
        .padding(12)
        .hudSurface(RoundedRectangle(cornerRadius: 16))
        // R67.1-5: the card must not grow over the speed readout at AX3+.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
    }

    /// The primary action, 48 pt tall. `wraps`: the label may take two lines (a long region).
    @ViewBuilder
    private func download(wraps: Bool) -> some View {
        Button(action: onDownload) {
            Text(PackOfferText.downloadLabel(title: offer.title, context: offer.context)).font(.callout.bold())
                .lineLimit(wraps ? 2 : 1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(wraps ? 0.8 : 1)
                .fixedSize(horizontal: !wraps, vertical: false)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(OfferActionStyle(prominent: true))
        .accessibilityLabel("Download \(offer.title), \(MapsText.size(offer.sizeBytes))")
    }

    /// "Not now" and "Never": quiet faces, each at least 48 pt tall.
    @ViewBuilder
    private func answers(stacked: Bool) -> some View {
        Button(action: onNotNow) {
            Text(PackOfferText.notNow).font(.callout.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, stacked ? 0 : 8)
                .frame(maxWidth: stacked ? .infinity : nil, minHeight: 48)
        }
        .buttonStyle(OfferActionStyle(prominent: false))
        .fixedSize(horizontal: !stacked, vertical: false)
        .accessibilityLabel("Not now")
        Button(action: onNever) {
            Text(PackOfferText.never).font(.callout.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, stacked ? 0 : 8)
                .frame(maxWidth: stacked ? .infinity : nil, minHeight: 48)
        }
        .buttonStyle(OfferActionStyle(prominent: false))
        .fixedSize(horizontal: !stacked, vertical: false)
        .accessibilityLabel("Never offer maps for \(offer.title)")
    }
}

/// The offer's buttons: a filled accent face for Download, a quiet face for
/// the others. Own style so three actions fit one row on a 375 pt phone.
private struct OfferActionStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color("AccentForeground") : HUDColors.text)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(prominent ? Color.accentColor : HUDColors.text.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview("Offer card") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))
        .padding(40).background(Color(.systemGray4))
}

#Preview("Offer card, only main roads") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000, context: .onlyMainRoads))
        .padding(40).background(Color(.systemGray4))
}

#Preview("Offer card, only main roads, dark") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000, context: .onlyMainRoads))
        .padding(40).background(Color(.systemGray4)).preferredColorScheme(.dark)
}

#Preview("Offer card, dark") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))
        .padding(40).background(Color(.systemGray4)).preferredColorScheme(.dark)
}

#Preview("Offer card, largest allowed type") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))
        .padding(40).background(Color(.systemGray4)).environment(\.dynamicTypeSize, .accessibility5)
}
