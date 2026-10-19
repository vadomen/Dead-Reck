import Foundation

// Pure decisions of the map HUD, layout E (UX-32): what the top-left card says,
// what the bottom-left zone stacks, the layout constants and the colours with
// their contrast. No SwiftUI, so every rule is unit-testable
// (`MapHUDTests`). The views are in `MapHUDViews.swift`.

/// GPS indicator state. `.off` is reserved for UX-9 (a), "GPS off, dead
/// reckoning only": nothing sets it yet.
enum HUDGPS: Hashable, Sendable {
    /// A fix arrived recently.
    case ok
    /// No fix (not receiving, or the last one is stale).
    case none
    /// The driver switched GPS off (UX-9 (a)); reserved.
    case off

    var label: String {
        switch self {
        case .ok: "GPS"
        case .none: "No GPS"
        case .off: "GPS off"
        }
    }

    var isFailed: Bool { self != .ok }
}

/// OBD indicator state.
enum HUDOBD: Hashable, Sendable {
    case connected
    case lost

    var label: String { self == .connected ? "OBD" : "OBD lost" }

    var isFailed: Bool { self == .lost }

    /// OBD counts as connected while a vehicle-speed reply is fresh (the UX-5
    /// rule's source). The session has no link-state accessor the UI may read,
    /// so "connected" means "its speed is arriving".
    static func from(speed: MapSpeedReadout) -> HUDOBD {
        speed.source == .obd ? .connected : .lost
    }
}

/// One GPS or OBD indicator in the card: glyph + short label.
struct HUDIndicator: Equatable, Sendable {
    var label: String
    /// Failed: the glyph is drawn slashed AND the warning colour is used, so
    /// the state never rests on colour alone.
    var failed: Bool
    /// This indicator belongs to the current speed source (UX-5 rule):
    /// drawn bold, with the label in the primary text colour.
    var emphasised: Bool

    var slashed: Bool { failed }
}

/// What the top-left card shows, derived from plain values. The recording row
/// is its own view (it alone reads the 16 Hz `session.live`).
struct MapHUDState: Equatable, Sendable {
    /// The big number: `54`, or `—`.
    var speedText: String
    var gps: HUDIndicator
    var obd: HUDIndicator
    /// Thermal row text, only when the state is not nominal.
    var thermal: String?
    /// One line for VoiceOver.
    var accessibilitySummary: String

    static func make(
        speed: MapSpeedReadout, gps: HUDGPS, obd: HUDOBD, thermal: ProcessInfo.ThermalState
    ) -> MapHUDState {
        let gpsIndicator = HUDIndicator(label: gps.label, failed: gps.isFailed, emphasised: speed.source == .gps)
        let obdIndicator = HUDIndicator(label: obd.label, failed: obd.isFailed, emphasised: speed.source == .obd)
        let thermalText: String? = thermal == .nominal ? nil : "Thermal " + ThermalText.label(thermal)
        var parts = ["\(speed.valueText) km/h", gpsIndicator.label, obdIndicator.label]
        if let thermalText { parts.append(thermalText) }
        return MapHUDState(
            speedText: speed.valueText, gps: gpsIndicator, obd: obdIndicator,
            thermal: thermalText,
            accessibilitySummary: parts.joined(separator: ", "))
    }

    /// GPS state from the map's own freshness (`GPSMapView.stale`) and the
    /// reserved UX-9 switch.
    static func gpsState(stale: Bool, switchedOff: Bool = false) -> HUDGPS {
        if switchedOff { return .off }
        return stale ? .none : .ok
    }
}

/// What the bottom-left zone can stack, left of the rail.
enum MapBottomItem: Hashable, Sendable, CaseIterable {
    /// At-a-stop pack offer (UX-8).
    case offerCard
    /// Fix recorded / zoom toast.
    case toast
    /// Calibration and OBD-lost banners (`NavigateStatus`).
    case statusLine
    case roadsWarning
    /// "Re-centre in N s".
    case resumeHint
    /// Two-line developer strip, only with "Navigation debug on map".
    case debugStrip
}

enum MapBottomZone {
    /// The items to show, top to bottom: the offer card on top, the debug
    /// strip lowest (just above the bottom edge / destination slot). Fixed
    /// order, so items never overlap whatever combination is present. The
    /// strip is gated by the setting alone; with it off nothing takes its place.
    static func items(
        offer: Bool, toast: Bool, status: Bool, roadsWarning: Bool, resumeHint: Bool, debugSetting: Bool
    ) -> [MapBottomItem] {
        var out: [MapBottomItem] = []
        if offer { out.append(.offerCard) }
        if toast { out.append(.toast) }
        if status { out.append(.statusLine) }
        if roadsWarning { out.append(.roadsWarning) }
        if resumeHint { out.append(.resumeHint) }
        if debugSetting { out.append(.debugStrip) }
        return out
    }
}

/// The two developer-strip lines (mockup: `ms/step (max) · ESS · hdg σ` and
/// `scale · dropped · on road`).
enum DebugStrip {
    static func lines(stats: NavStatsDisplay?) -> [String] {
        guard let stats else { return ["nav: idle"] }
        let parts = stats.parts
        let onRoad = RoadDebugOverlay.shareLine(enabled: true, share: stats.onRoadShare) ?? ""
        return [
            parts.prefix(3).joined(separator: " · "),
            (Array(parts.dropFirst(3)) + [onRoad]).joined(separator: " · "),
        ]
    }
}

/// Layout constants, points.
enum MapLayout {
    /// Every map control (rail buttons) is at least this big; others 44.
    static let controlSize: Double = 56
    static let minTapTarget: Double = 44
    static let railGap: Double = 10
    static let edgeInset: Double = 12
    /// The OSM line sits in this band at the very bottom, beside Apple's marks.
    static let attributionBand: Double = 22
    /// Height of the full-width destination field (UX-19) at the bottom. 0 in
    /// v1.0: nothing is drawn; the rail and the bottom-left zone lift by it
    /// when it exists.
    static let bottomSlotHeight: Double = 0

    /// Gap between the screen's bottom (safe area) and the rail / bottom zone.
    static func bottomInset(slot: Double = bottomSlotHeight) -> Double {
        attributionBand + 8 + slot
    }

    /// Width kept free on the right for the rail: the bottom-left zone ends here.
    static var railReserved: Double { edgeInset + controlSize + edgeInset }
}

// MARK: - Colours and contrast (UX-13)

/// sRGB colour with alpha, 0...255 channels.
struct HUDRGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    /// This colour over an opaque backdrop.
    func over(_ back: HUDRGB) -> HUDRGB {
        HUDRGB(
            r: r * a + back.r * (1 - a), g: g * a + back.g * (1 - a), b: b * a + back.b * (1 - a))
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double {
            let s = c / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio of two opaque colours.
    static func contrast(_ x: HUDRGB, _ y: HUDRGB) -> Double {
        let a = x.luminance, b = y.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Explicit HUD colours per scheme: no system materials, so the contrast
/// holds over any map. The card is translucent; the worst backdrops are pure
/// black and pure white, and `MapHUDTests` checks both.
struct HUDScheme: Equatable, Sendable {
    var card: HUDRGB
    var text: HUDRGB
    var muted: HUDRGB
    /// Failed GPS / OBD, thermal.
    var warn: HUDRGB
    /// Rail button face (inactive).
    var button: HUDRGB
    /// Active rail button face and its glyph.
    var accent: HUDRGB
    var onAccent: HUDRGB
    /// Accent-coloured glyph on the card (the calibrating icon): lighter in dark.
    var accentOnCard: HUDRGB
    /// The recording dot.
    var record: HUDRGB

    static let light = HUDScheme(
        card: HUDRGB(r: 255, g: 255, b: 255, a: 0.96), text: HUDRGB(r: 18, g: 22, b: 29),
        muted: HUDRGB(r: 74, g: 82, b: 96), warn: HUDRGB(r: 154, g: 67, b: 0),
        button: HUDRGB(r: 255, g: 255, b: 255, a: 0.97), accent: HUDRGB(r: 31, g: 99, b: 214),
        onAccent: HUDRGB(r: 255, g: 255, b: 255), accentOnCard: HUDRGB(r: 31, g: 99, b: 214),
        record: HUDRGB(r: 200, g: 20, b: 20))

    static let dark = HUDScheme(
        card: HUDRGB(r: 20, g: 24, b: 32, a: 0.92), text: HUDRGB(r: 244, g: 246, b: 250),
        muted: HUDRGB(r: 174, g: 182, b: 195), warn: HUDRGB(r: 255, g: 176, b: 87),
        button: HUDRGB(r: 38, g: 44, b: 56, a: 0.96), accent: HUDRGB(r: 47, g: 111, b: 224),
        onAccent: HUDRGB(r: 255, g: 255, b: 255), accentOnCard: HUDRGB(r: 125, g: 172, b: 255),
        record: HUDRGB(r: 255, g: 90, b: 80))

    /// Worst-case contrast of `foreground` on `face` over black and white map pixels.
    func worstContrast(_ foreground: HUDRGB, on face: HUDRGB) -> Double {
        [HUDRGB(r: 0, g: 0, b: 0), HUDRGB(r: 255, g: 255, b: 255)].map { back in
            HUDRGB.contrast(foreground.over(face.over(back)), face.over(back))
        }.min() ?? 0
    }
}

// MARK: - DEBUG fakes (screenshots)

/// `-uiFakeHUD ok,gpsLost,obdLost,recording,debug,thermal,banner`: synthetic HUD
/// inputs for simulator screenshots (the simulator has no OBD and a real
/// position). Parsed here so the parsing is testable; applied by `MapScreen`
/// in DEBUG builds only. Comma-separated, unknown tokens ignored; an empty or
/// missing value means no fakes.
struct HUDFakes: Equatable, Sendable {
    var isActive = false
    var gpsLost = false
    var obdLost = false
    var recording = false
    var debugStrip = false
    var thermal = false
    /// The OBD-lost banner (`NavigateStatus.waitingForOBD`).
    var banner = false

    static func parse(_ value: String?) -> HUDFakes {
        var out = HUDFakes()
        for token in (value ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "ok": out.isActive = true
            case "gpsLost": out.isActive = true; out.gpsLost = true
            case "obdLost": out.isActive = true; out.obdLost = true
            case "recording": out.isActive = true; out.recording = true
            case "debug": out.isActive = true; out.debugStrip = true
            case "thermal": out.isActive = true; out.thermal = true
            case "banner": out.isActive = true; out.banner = true
            default: break
            }
        }
        return out
    }

    /// The speed shown: 27 km/h from OBD, or from GPS when OBD is "lost".
    var speed: MapSpeedReadout {
        MapSpeedReadout(source: obdLost ? .gps : .obd, kmh: 27, quality: .good)
    }
}
