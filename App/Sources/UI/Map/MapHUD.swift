import Foundation

// Pure decisions of the map HUD, layout E (UX-32): what the top-left card says,
// what the bottom-left zone stacks, the layout constants and the colours with
// their contrast. No SwiftUI, so every rule is unit-testable
// (`MapHUDTests`). The views are in `MapHUDViews.swift`.

/// GPS indicator state. `.off` is the driver's switch (UX-9 (a)), "GPS off,
/// dead reckoning only"; its glyph (`location.slash.circle`) differs from
/// `.none`'s (`location.slash.fill`), so the two never rest on colour.
enum HUDGPS: Hashable, Sendable {
    /// A fix arrived recently.
    case ok
    /// No fix (not receiving, or the last one is stale).
    case none
    /// The driver switched GPS off (UX-9 (a)).
    case off

    var label: String {
        switch self {
        case .ok: String(localized: "GPS")
        case .none: String(localized: "No GPS")
        case .off: String(localized: "GPS off")
        }
    }

    var isFailed: Bool { self != .ok }
}

/// OBD indicator state: the link's, not the speed's. Which speed is shown
/// (and so which indicator is emphasised) stays the UX-5 rule's decision.
enum HUDOBD: Hashable, Sendable {
    case connected
    /// A link that was up in this app session has dropped.
    case lost
    /// The currently paired adapter has not connected in this app session, or
    /// none is paired (never paired, or Forget): nothing was lost, so this is
    /// muted, not a warning.
    case none

    var label: String {
        switch self {
        case .connected: String(localized: "OBD")
        case .lost: String(localized: "OBD lost")
        case .none: String(localized: "No OBD")
        }
    }

    /// Only "lost" is a warning.
    var isFailed: Bool { self == .lost }

    /// Drawn with the slashed glyph: lost, and also "No OBD" (in the muted colour).
    var isSlashed: Bool { self != .connected }

    /// Connected while the adapter is initialised and talking to the car
    /// (`ready`, `polling`; the ELM session's `retrying` is still `polling`),
    /// whether or not a speed reply is fresh: a silent engine on a live link
    /// reads "OBD". Otherwise "OBD lost" if a link was up earlier in this app
    /// session (`everConnected`: scanning, connecting, initialising,
    /// reconnecting, failed, Bluetooth off), and "No OBD" if none ever was.
    static func from(link: OBDLinkState?, everConnected: Bool) -> HUDOBD {
        switch link {
        case .ready?, .polling?: .connected
        default: everConnected ? .lost : .none
        }
    }

    /// Whether `link` means the adapter is up (feeds `MapViewModel.obdEverConnected`).
    static func isUp(_ link: OBDLinkState?) -> Bool {
        from(link: link, everConnected: false) == .connected
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

    /// "No OBD" is slashed too but not `failed`: muted colour, no warning.
    var absent = false

    var slashed: Bool { failed || absent }

    /// The driver's GPS switch is off: drawn with its own glyph, not the "No GPS" one.
    var switchedOff = false
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
        let gpsIndicator = HUDIndicator(
            label: gps.label, failed: gps.isFailed, emphasised: speed.source == .gps, switchedOff: gps == .off)
        let obdIndicator = HUDIndicator(
            label: obd.label, failed: obd.isFailed, emphasised: speed.source == .obd, absent: obd == .none)
        let thermalText: String? = thermal == .nominal ? nil : String(localized: "Thermal \(ThermalText.label(thermal))")
        var parts = [String(localized: "\(speed.valueText) km/h"), gpsIndicator.label, obdIndicator.label]
        if let thermalText { parts.append(thermalText) }
        return MapHUDState(
            speedText: speed.valueText, gps: gpsIndicator, obd: obdIndicator,
            thermal: thermalText,
            accessibilitySummary: parts.joined(separator: ", "))
    }

    /// GPS state for the HUD (UX-9 (a), UX-22).
    /// - The driver's switch (`switchedOff`, read from the session at the tap)
    ///   wins: immediate, and the engine's own flag lags it by the tap buffer
    ///   (OR-ing the engine's flag in would show "GPS off" for a moment after
    ///   Use GPS), so the engine's `switchedOff` is deliberately not used here.
    /// - With an engine state (a navigating session whose estimate is shown):
    ///   "GPS" only while the engine used a valid-speed fix in the last 5 s,
    ///   else "No GPS". Fixes arriving that the engine does not use
    ///   (network-only, or spoofed ones it rejects) are "No GPS".
    /// - Without one (no run, no estimate shown, e.g. Navigate without OBD):
    ///   the map's own freshness (`stale`).
    /// - An engine state tagged with another run than `currentRun` (the
    ///   previous run's, still held for a frame) is ignored (R76.2-1): the
    ///   stale logic answers, which is "No GPS" before the new run has a fix.
    static func gpsState(
        stale: Bool, switchedOff: Bool = false, engine: EngineGPS? = nil, currentRun: Int? = nil
    ) -> HUDGPS {
        if switchedOff { return .off }
        if let engine, belongs(engine, to: currentRun) { return engine.inUse ? .ok : .none }
        return stale ? .none : .ok
    }

    /// The engine state is the live run's (or untagged: the demo's feed).
    static func belongs(_ engine: EngineGPS, to currentRun: Int?) -> Bool {
        engine.run == nil || engine.run == currentRun
    }

    /// The run the voice may take a baseline for (R76.2-1, R76.3-1): nil until
    /// the HUD state comes from the live run's own engine, so a run starts
    /// silent whatever the previous run left behind. Rule (user decision):
    /// no run (`current` nil, e.g. Navigate without OBD) -> no voice baseline
    /// and silence, the same condition as the GPS off button. While a run
    /// exists the estimate is always shown.
    static func voiceRun(current: Int?, engine: EngineGPS?) -> Int? {
        guard let current else { return nil }
        guard let engine, belongs(engine, to: current) else { return nil }
        return current
    }
}

/// The rail's GPS switch (UX-9 (a)): what it shows and says for the switch and
/// the run. Shown always, so the rail does not jump; without a run it is
/// disabled (nothing to switch: the switch belongs to a run).
struct GPSSwitchControl: Equatable, Sendable {
    var symbol: String
    /// The visible caption under the button.
    var caption: String
    var accessibilityLabel: String
    /// Voice Control names: the visible text.
    var inputLabels: [String]
    /// Filled while GPS is off.
    var active: Bool
    var enabled: Bool

    static func make(switchOn: Bool, runActive: Bool) -> GPSSwitchControl {
        if switchOn {
            let caption = String(localized: "GPS off (rail caption)", comment: "Under the rail's GPS button. The rail is 80 pt wide, so the Ukrainian caption is the short form; the HUD label and the spoken phrase are the full «GPS вимкнено».")
            return GPSSwitchControl(
                symbol: "location.circle", caption: caption,
                accessibilityLabel: String(localized: "Turn GPS off, dead reckoning only"), inputLabels: [caption],
                active: false, enabled: runActive)
        }
        let caption = String(localized: "Use GPS (rail caption)", comment: "Under the rail's GPS button; short Ukrainian form «Увімк. GPS» (80 pt rail).")
        return GPSSwitchControl(
            symbol: "location.slash.circle", caption: caption,
            accessibilityLabel: String(localized: "Turn GPS back on"), inputLabels: [caption],
            active: true, enabled: runActive)
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
    /// "Finding your position... keep driving" while the estimate is unconverged or km-wide (C6).
    case positionStatus
    /// "Restored · n min ago · not yet confirmed" while a restored estimate is unconfirmed (UX-20).
    case restoreStatus
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
        offer: Bool, toast: Bool, status: Bool, positionStatus: Bool = false, restoreStatus: Bool = false, roadsWarning: Bool,
        resumeHint: Bool, debugSetting: Bool
    ) -> [MapBottomItem] {
        var out: [MapBottomItem] = []
        if offer { out.append(.offerCard) }
        if toast { out.append(.toast) }
        if status { out.append(.statusLine) }
        if restoreStatus { out.append(.restoreStatus) }
        if positionStatus { out.append(.positionStatus) }
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
        attributionBand + aboveCreditGap + slot
    }

    /// Space between the credit band and the lowest rail button / stack item.
    static let aboveCreditGap: Double = 8

    /// Height from the top of the map covered by the safe area and the HUD
    /// card (speed, indicators): the ellipse fit keeps clear of it.
    static let hudReserved: Double = 150
    /// Height above the bottom inset covered by the offer card (the compact
    /// card, its three actions in one row): the fit keeps clear of it.
    static let offerCardReserved: Double = 140
    /// Clear space kept above the card (the old 140 pt was a ~120 pt card plus this).
    static let offerCardGap: Double = 20

    /// What the offer or in-car card covers: its measured height plus the gap;
    /// the default until it has been measured. The Ukrainian offer card stacks
    /// Download above the two answers and is about 60 pt taller than English.
    static func offerReserved(cardHeight: Double?) -> Double {
        guard let cardHeight, cardHeight.isFinite, cardHeight > 0 else { return offerCardReserved }
        return cardHeight + offerCardGap
    }

    /// Rail: four 56 pt buttons (GPS switch, North up, Following, Settings), gaps, and the GPS caption.
    static let railButtonCount = 4
    static let railCaptionHeight: Double = 18
    static var railHeight: Double {
        Double(railButtonCount) * controlSize + Double(railButtonCount - 1) * railGap + railCaptionHeight
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

/// `-uiFakeHUD ok,gpsLost,gpsOff,obdLost,obdNone,recording,debug,thermal,banner,calibrating,stopped`: synthetic HUD
/// inputs for simulator screenshots (the simulator has no OBD and a real
/// position). Parsed here so the parsing is testable; applied by `MapScreen`
/// in DEBUG builds only. Comma-separated, unknown tokens ignored; an empty or
/// missing value means no fakes.
struct HUDFakes: Equatable, Sendable {
    var isActive = false
    var gpsLost = false
    /// The driver's GPS switch off (UX-9 (a)); the rail button is enabled.
    var gpsOff = false
    var obdLost = false
    var obdNone = false
    var recording = false
    var debugStrip = false
    var thermal = false
    /// The OBD-lost banner (`NavigateStatus.waitingForOBD`).
    var banner = false
    /// UX-35 screenshots: a short good line, then a stop with scattered
    /// Wi-Fi-like fixes (`MapPreviewData.stopTrack`).
    var scatter = false
    /// The keep-still banner (`NavigateStatus.calibrating`), for the in-car mount card.
    var calibrating = false
    /// OBD speed 0 km/h (a stop).
    var stopped = false
    /// A synthetic estimate on the map (screenshots; `MapPreviewData.fakeNav`).
    var nav: FakeNav?
    /// UX-15 screenshots: the "Restored · n min ago · not yet confirmed" line (12 min), on `navEllipse`.
    var restored = false

    /// `navFinding`: not converged, a km-wide ellipse. `navEllipse`: converged,
    /// 90 x 20 m across the track. `navRoad`: converged on a road, with the matched edge.
    enum FakeNav: String, Equatable, Sendable { case finding = "navFinding", ellipse = "navEllipse", road = "navRoad" }

    static func parse(_ value: String?) -> HUDFakes {
        var out = HUDFakes()
        for token in (value ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "ok": out.isActive = true
            case "gpsLost": out.isActive = true; out.gpsLost = true
            case "gpsOff": out.isActive = true; out.gpsOff = true
            case "obdLost": out.isActive = true; out.obdLost = true
            case "obdNone": out.isActive = true; out.obdNone = true
            case "recording": out.isActive = true; out.recording = true
            case "debug": out.isActive = true; out.debugStrip = true
            case "thermal": out.isActive = true; out.thermal = true
            case "banner": out.isActive = true; out.banner = true
            case "scatter": out.isActive = true; out.scatter = true
            case "calibrating": out.isActive = true; out.calibrating = true
            case "stopped": out.isActive = true; out.stopped = true
            case "restored": out.isActive = true; out.restored = true
            case "navFinding", "navEllipse", "navRoad":
                out.isActive = true
                out.nav = FakeNav(rawValue: token)
            default: break
            }
        }
        if out.restored, out.nav == nil { out.nav = .ellipse }
        return out
    }

    /// The OBD indicator: lost with `obdLost`, "No OBD" with `obdNone`, else connected.
    var obd: HUDOBD { obdLost ? .lost : (obdNone ? .none : .connected) }

    /// The speed shown: 27 km/h from OBD, or from GPS when OBD is "lost".
    var speed: MapSpeedReadout {
        // GPS off and no OBD: no fallback to GPS speed, a dash (the model's rule).
        if gpsOff && (obdLost || obdNone) { return .none }
        return MapSpeedReadout(source: (obdLost || obdNone) ? .gps : .obd, kmh: stopped ? 0 : 27, quality: .good)
    }
}
