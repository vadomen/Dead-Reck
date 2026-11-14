import SwiftUI

/// The raw-fix dot as the map draws it: a filled disc with a white ring.
/// Shared by the map's marker and the legend swatches.
struct RawFixDot: View {
    var color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white, lineWidth: 3))
    }
}

/// FuGPS's own position as the map draws it (north-up, or heading-up before the
/// heading converged): a blue disc with a white ring. Shared by `NavMarker`
/// and the legend's first row.
struct EstimateDot: View {
    static let color: Color = .blue

    var body: some View {
        Circle()
            .fill(Self.color)
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(.white, lineWidth: 3))
    }
}

/// One legend row: a kind of dot and its words. The words carry the meaning;
/// the colour only repeats it.
struct GPSLegendRow: Identifiable {
    enum Kind: Hashable { case estimate, band(AccuracyBand), stale }
    var kind: Kind
    var text: String
    var color: Color
    var id: Kind { kind }
}

/// What the legend says, from the same sources as the map: the bands and their
/// bounds (`AccuracyBand`), the colour function (`GPSMapView.color`) and the
/// stale rule (`GPSMapView.staleAfter`).
enum GPSLegendContent {
    static let intro = String(localized: "FuGPS's position is the blue dot with its blue area. The phone's GPS is the green, yellow, orange, red or grey dot with its circle; when GPS is jammed it can be far off. When the map turns with the car (\"Heading up\"), a dot can become an arrow.")

    static var staleSeconds: Int { Int(GPSMapView.staleAfter.components.seconds) }

    static func text(for kind: GPSLegendRow.Kind) -> String {
        switch kind {
        case .estimate: String(localized: "FuGPS — position estimate")
        case .band(.good): String(localized: "Good — within \(Int(AccuracyBand.good.upperBoundM ?? 0)) m")
        case .band(.fair): String(localized: "Fair — within \(Int(AccuracyBand.fair.upperBoundM ?? 0)) m")
        case .band(.poor): String(localized: "Poor — within \(Int(AccuracyBand.poor.upperBoundM ?? 0)) m")
        // `.bad` has no bound of its own: it starts where `.poor` ends.
        case .band(.bad): String(localized: "Bad — worse than \(Int(AccuracyBand.poor.upperBoundM ?? 0)) m")
        case .stale: String(localized: "Stale — no new fix for \(staleSeconds) s")
        }
    }

    static var rows: [GPSLegendRow] {
        [GPSLegendRow(kind: .estimate, text: text(for: .estimate), color: EstimateDot.color)]
        + AccuracyBand.allCases.map { band in
            GPSLegendRow(kind: .band(band), text: text(for: .band(band)), color: GPSMapView.color(band, stale: false))
        } + [
            GPSLegendRow(kind: .stale, text: text(for: .stale), color: GPSMapView.color(.good, stale: true))
        ]
    }
}

/// A short sheet, opened from the map's GPS indicator and from Settings → About.
/// Reading only: it touches no sensor, engine or recording.
struct GPSLegendSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder private func swatchDot(_ row: GPSLegendRow) -> some View {
        if row.kind == .estimate { EstimateDot() } else { RawFixDot(color: row.color) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(GPSLegendContent.intro)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(GPSLegendContent.rows) { row in
                        HStack(spacing: 16) {
                            swatchDot(row)
                                .background(Circle().fill(row.color.opacity(0.2)).frame(width: 44, height: 44))
                                .overlay(Circle().stroke(row.color, lineWidth: 1).frame(width: 44, height: 44))
                                .frame(width: 48, height: 48)
                                .accessibilityHidden(true)
                            Text(row.text)
                                .font(.title3.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("What the map dot means")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}

#Preview("GPS legend") {
    GPSLegendSheet()
}
