import SwiftUI

/// Wording of the at-a-stop offer card (UX-8 (2)).
enum PackOfferText {
    static func question(title: String, sizeBytes: Int64) -> String {
        "You are in \(title), no road map. Download \(MapsText.size(sizeBytes))?"
    }
    static let download = "Download"
    static let notNow = "Not now"
    static let never = "Never for this region"
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

    private var shown: PackOfferMonitor.Offer? {
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
        VStack(alignment: .leading, spacing: 10) {
            Text(PackOfferText.question(title: offer.title, sizeBytes: offer.sizeBytes))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: onDownload) {
                    Text(PackOfferText.download).font(.headline.bold()).frame(maxWidth: .infinity, minHeight: 56)
                }
                .prominentButton()
                .accessibilityLabel("Download \(offer.title), \(MapsText.size(offer.sizeBytes))")
                Button(action: onNotNow) {
                    Text(PackOfferText.notNow).font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .tint(HUDColors.text)
                .accessibilityLabel("Not now")
            }
            Button(action: onNever) {
                Text(PackOfferText.never).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
                .tint(HUDColors.text)
            .accessibilityLabel("Never offer maps for \(offer.title)")
        }
        .padding(12)
        .hudSurface(RoundedRectangle(cornerRadius: 16))
        // R67.1-5: the card must not grow over the speed readout at AX3+.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
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
