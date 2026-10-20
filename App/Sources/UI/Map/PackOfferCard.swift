import SwiftUI

/// Wording of the at-a-stop offer card (UX-8 (2), compact form R68.1-3).
enum PackOfferText {
    /// The one line: what is missing and what it costs.
    static func summary(sizeBytes: Int64) -> String {
        "No road map here · \(MapsText.size(sizeBytes))"
    }
    /// The same line with the region, used when it fits on one line.
    static func summary(title: String, sizeBytes: Int64) -> String {
        summary(sizeBytes: sizeBytes) + " · " + title
    }
    static let download = "Download"
    static let notNow = "Not now"
    static let never = "Never"
}

/// The card wired to the monitor. Its own view, so only it observes `offer`.
struct PackOfferCard: View {
    var monitor: PackOfferMonitor

    var body: some View {
        Group {
            if let offer = shown {
                PackOfferCardView(
                    offer: offer,
                    onDownload: { monitor.download() },
                    onNotNow: { monitor.notNow() },
                    onNever: { monitor.never() })
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
        if UserDefaults.standard.bool(forKey: "uiFakeOffer") {
            return PackOfferMonitor.Offer(name: "zz-01", title: "Region A", sizeBytes: 35_000_000)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One line; the region goes on a second line only when it does not fit.
            ViewThatFits(in: .horizontal) {
                Text(PackOfferText.summary(title: offer.title, sizeBytes: offer.sizeBytes))
                    .font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PackOfferText.summary(sizeBytes: offer.sizeBytes)).font(.headline)
                    Text(offer.title).font(.subheadline).foregroundStyle(HUDColors.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // Three actions in one row; at the largest sizes they stack instead.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(spacing: 8) { actions }
            }
        }
        .padding(12)
        .hudSurface(RoundedRectangle(cornerRadius: 16))
        // R67.1-5: the card must not grow over the speed readout at AX3+.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onDownload) {
            Text(PackOfferText.download).font(.headline.bold()).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .prominentButton()
        .accessibilityLabel("Download \(offer.title), \(MapsText.size(offer.sizeBytes))")
        Button(action: onNotNow) {
            Text(PackOfferText.notNow).font(.headline).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(HUDColors.text)
        .accessibilityLabel("Not now")
        Button(action: onNever) {
            Text(PackOfferText.never).font(.headline).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(HUDColors.text)
        .accessibilityLabel("Never offer maps for \(offer.title)")
    }
}

#Preview("Offer card") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))
        .padding(40).background(Color(.systemGray4))
}

#Preview("Offer card, dark") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))
        .padding(40).background(Color(.systemGray4)).preferredColorScheme(.dark)
}

#Preview("Offer card, largest allowed type") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))
        .padding(40).background(Color(.systemGray4)).environment(\.dynamicTypeSize, .accessibility5)
}
