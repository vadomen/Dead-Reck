import SwiftUI
import UIKit

// The views of the map HUD, layout E (UX-32). Plain values in, no sensors:
// decisions are in `MapHUD.swift`.

extension HUDRGB {
    fileprivate var uiColor: UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

/// The HUD colours (explicit, with checked contrast: `HUDScheme`).
enum HUDColors {
    private static func pick(_ keyPath: KeyPath<HUDScheme, HUDRGB>) -> Color {
        Color(uiColor: UIColor { traits in
            (traits.userInterfaceStyle == .dark ? HUDScheme.dark : HUDScheme.light)[keyPath: keyPath].uiColor
        })
    }

    static let card = pick(\.card)
    static let text = pick(\.text)
    static let muted = pick(\.muted)
    static let warn = pick(\.warn)
    static let button = pick(\.button)
    static let accent = pick(\.accent)
    static let onAccent = pick(\.onAccent)
    static let accentOnCard = pick(\.accentOnCard)
    static let record = pick(\.record)
}

extension View {
    /// A HUD card face: explicit colour (no material) and the text colour that
    /// goes with it.
    func hudSurface<S: Shape>(_ shape: S) -> some View {
        self
            .foregroundStyle(HUDColors.text)
            .background(HUDColors.card, in: shape)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

/// The top-left card: speed, GPS and OBD indicators, thermal when not
/// nominal, the recording row while recording.
struct MapHUDCard<Extra: View, Recording: View>: View {
    var state: MapHUDState
    /// The recording row is shown: it is 44 pt tall and ends the card (no bottom padding).
    var hasRecording = false
    var onSpeedLongPress: () -> Void = {}
    /// Next to "km/h": the calibrating-heading icon.
    @ViewBuilder var extra: () -> Extra
    /// The recording row (a button that asks to stop); empty while idle.
    @ViewBuilder var recording: () -> Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(state.speedText)
                        .font(.system(size: 52, weight: .bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        // Hidden switch: 1 s long-press toggles the navigation debug strip.
                        .onLongPressGesture(minimumDuration: 1, perform: onSpeedLongPress)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("km/h")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HUDColors.muted)
                        extra()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HUDIndicatorLabel(indicator: state.gps, symbol: "location.fill", slashedSymbol: "location.slash.fill")
                    HUDIndicatorLabel(indicator: state.obd, symbol: "cable.connector", slashedSymbol: "cable.connector.slash")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilitySummary)
            if let thermal = state.thermal {
                Label(thermal, systemImage: "thermometer.high")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HUDColors.warn)
                    .padding(.top, 2)
            }
            recording()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, hasRecording ? 0 : 8)
        .fixedSize(horizontal: true, vertical: false)
        .hudSurface(RoundedRectangle(cornerRadius: 18))
    }
}

/// Glyph + short label. Failed: slashed glyph and warning colour. The
/// indicator of the current speed source is bold and in the text colour.
struct HUDIndicatorLabel: View {
    var indicator: HUDIndicator
    var symbol: String
    var slashedSymbol: String
    /// The glyph for the driver's switch being off (GPS only).
    var switchedOffSymbol = "location.slash.circle"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: indicator.switchedOff ? switchedOffSymbol : (indicator.slashed ? slashedSymbol : symbol))
                .font(.system(size: 12, weight: indicator.emphasised ? .heavy : .medium))
                .frame(width: 16)
            Text(indicator.label)
                .font(.system(size: 12, weight: indicator.emphasised ? .heavy : .medium))
        }
        .foregroundStyle(indicator.failed ? HUDColors.warn : (indicator.emphasised ? HUDColors.text : HUDColors.muted))
    }
}

/// A 56 pt round rail button. Active: filled in the accent colour with a filled
/// glyph and a ring; inactive: plain face with an outline glyph, so the state
/// does not rest on colour.
struct HUDRailButton: View {
    var symbol: String
    var label: String
    var active: Bool
    /// Visible text under the button (the GPS switch); nil for the others.
    var caption: String?
    /// Voice Control names; empty keeps the system default (the label).
    var inputLabels: [String]
    var action: () -> Void

    init(
        symbol: String, label: String, active: Bool, caption: String? = nil, inputLabels: [String] = [],
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.active = active
        self.caption = caption
        self.inputLabels = inputLabels
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? HUDColors.onAccent : HUDColors.text)
                    .frame(width: MapLayout.controlSize, height: MapLayout.controlSize)
                    .background(active ? HUDColors.accent : HUDColors.button, in: Circle())
                    .overlay(Circle().strokeBorder(active ? HUDColors.onAccent : HUDColors.muted, lineWidth: active ? 3 : 1.5)
                        .padding(active ? 3 : 0))
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(HUDColors.text)
                        .padding(.horizontal, 6)
                        .frame(height: MapLayout.railCaptionHeight - 2)
                        .background(HUDColors.card, in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityInputLabels(inputLabels.isEmpty ? [label] : inputLabels)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The two-line developer strip, monospaced; only while "Navigation debug on map" is on.
struct MapDebugStrip: View {
    var lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(HUDColors.muted)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HUDColors.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// "© OpenStreetMap contributors": one small line at the very bottom edge,
/// beside Apple's marks (UX-33).
struct MapAttributionLine: View {
    var body: some View {
        Text(MapAttribution.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(HUDColors.text)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(HUDColors.card, in: Capsule())
            .padding(.bottom, 4)
            .accessibilityLabel(MapAttribution.text)
    }
}

#if DEBUG
/// `-uiNoMapTiles 1`: a plain synthetic basemap (no real place) with a road and
/// the car marker where the follow camera puts it, for screenshots.
struct SyntheticBasemap: View {
    /// Car's distance from the top as a fraction of the height (`CarPlacement`).
    var carFromTop: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let dark = scheme == .dark
            let carY = geo.size.height * carFromTop
            ZStack {
                (dark ? Color(red: 0.11, green: 0.13, blue: 0.18) : Color(red: 0.93, green: 0.94, blue: 0.95))
                Path { p in
                    p.move(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                    p.addLine(to: CGPoint(x: geo.size.width / 2, y: -20))
                    p.move(to: CGPoint(x: -20, y: geo.size.height * 0.3))
                    p.addLine(to: CGPoint(x: geo.size.width + 20, y: geo.size.height * 0.26))
                    p.move(to: CGPoint(x: -20, y: geo.size.height * 0.8))
                    p.addLine(to: CGPoint(x: geo.size.width + 20, y: geo.size.height * 0.76))
                }
                .stroke(dark ? Color(white: 0.24) : Color.white, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                Image(systemName: "location.north.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                    .shadow(color: .white, radius: 1)
                    .position(x: geo.size.width / 2, y: carY)
            }
        }
        .ignoresSafeArea()
    }
}
#endif
