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
/// never covers the speed (top) or the stop control (bottom left).
struct PackOfferCardView: View {
    let offer: PackOfferMonitor.Offer
    var onDownload: () -> Void = {}
    var onNotNow: () -> Void = {}
    var onNever: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PackOfferText.question(title: offer.title, sizeBytes: offer.sizeBytes))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: onDownload) {
                    Text(PackOfferText.download).font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                }
                .prominentButton()
                .accessibilityLabel("Download \(offer.title), \(MapsText.size(offer.sizeBytes))")
                Button(action: onNotNow) {
                    Text(PackOfferText.notNow).font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Not now")
            }
            Button(action: onNever) {
                Text(PackOfferText.never).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Never offer maps for \(offer.title)")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Offer card") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))
        .padding(.vertical, 40).background(Color(.systemGray4))
}

#Preview("Offer card, dark") {
    PackOfferCardView(offer: .init(name: "zz-01", title: "Region A", sizeBytes: 35_000_000))
        .padding(.vertical, 40).background(Color(.systemGray4)).preferredColorScheme(.dark)
}
