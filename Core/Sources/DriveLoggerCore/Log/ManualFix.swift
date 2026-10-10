import Foundation

/// `manualFix` (format v3): a position the driver marked on the map — "I'm
/// here" — as ground truth for evaluating dead reckoning offline, above all
/// where GNSS is jammed or absent (tunnels).
///
/// An on-disk type: every stored property name is a JSON key and part of the
/// format. Since the double-tap flow the event's `t` is the tap time on the
/// session clock and equals `pressedT`: the row is written up to a few seconds
/// later (an undo window) but stamped with the moment of the tap. Recordings
/// made before that were written at confirm time: their `t − pressedT` is the
/// confirm delay, and they were gated at 10 km/h.
/// `speedSource` is stored as a `String` (like the other vocabularies) so a
/// value added by a later build still decodes; `SpeedSource` produces it.
///
/// The speed fields describe the conditions of the fix. There is no speed
/// limit: a fix while driving is recorded with its speed.
public struct ManualFixSample: Hashable, Sendable, Codable {
    /// Degrees, WGS 84, of the confirmed pin.
    public var latitude: Double
    /// Degrees, WGS 84, of the confirmed pin.
    public var longitude: Double
    /// When the pin was placed, on the session clock: the tap time. Equal to
    /// the event's `t` (older recordings: the start of the long-press, and
    /// `t − pressedT` is the confirm delay).
    public var pressedT: MonotonicTimestamp
    /// Visible map span at the tap, in metres: how precisely the pin could
    /// be placed. Absent when the UI did not report one.
    public var mapSpanM: Double?
    /// Last vehicle speed from the primary ECU (`7E8`) at the tap, km/h.
    /// Absent when the link had none (not connected, or no reply yet).
    /// Recorded even when it was too old to count (`speedSource` then is not
    /// `obd`).
    public var obdSpeedKmh: Double?
    /// When that OBD reply arrived, on the session clock: the `t` of its
    /// `obd` row. `t − obdSpeedT` is how old the speed was. Present exactly
    /// when `obdSpeedKmh` is.
    public var obdSpeedT: MonotonicTimestamp?
    /// Speed of the latest reference GNSS fix at the tap, km/h, whenever that
    /// fix reported a speed (`speed ≥ 0`), however old or inaccurate.
    /// **Reference only**, recorded for analysis; it is the fix's speed only
    /// when `speedSource` is `gps`.
    public var gpsSpeedKmh: Double?
    /// Which speed describes the fix: `obd`, `gps` or `unknown`
    /// (`SpeedSource` raw values).
    public var speedSource: String
    /// The speed `speedSource` names, km/h (the speed of the fix). Absent when
    /// `speedSource` is `unknown`. Named for the 10 km/h gate older builds
    /// applied; the name is on disk and stays.
    public var gateSpeedKmh: Double?
    /// Optional free text: trimmed, at most `maxNoteLength` characters,
    /// absent when empty. The double-tap flow writes none; older recordings
    /// may carry one.
    public var note: String?

    public init(
        latitude: Double,
        longitude: Double,
        pressedT: MonotonicTimestamp,
        mapSpanM: Double? = nil,
        obdSpeedKmh: Double? = nil,
        obdSpeedT: MonotonicTimestamp? = nil,
        gpsSpeedKmh: Double? = nil,
        speedSource: String,
        gateSpeedKmh: Double? = nil,
        note: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.pressedT = pressedT
        self.mapSpanM = mapSpanM
        self.obdSpeedKmh = obdSpeedKmh
        self.obdSpeedT = obdSpeedT
        self.gpsSpeedKmh = gpsSpeedKmh
        self.speedSource = speedSource
        self.gateSpeedKmh = gateSpeedKmh
        self.note = note
    }

    /// `speedSource` vocabulary. Raw values are on-disk strings: never
    /// rename them.
    public enum SpeedSource: String, Hashable, Sendable, CaseIterable {
        /// Primary-ECU vehicle speed (PID 0x0D from `7E8`), reply at most
        /// `ManualFixGate.maxOBDAgeS` old.
        case obd
        /// The reference GNSS fix's speed: no fresh OBD speed, and the fix
        /// had a valid speed, speed accuracy and position within 100 m and
        /// was at most `ManualFixGate.maxFixAgeS` old.
        case gps
        /// Neither was usable.
        case unknown
    }

    /// Longest note kept, in characters (grapheme clusters).
    public static let maxNoteLength = 80

    /// `note` as written: whitespace and newlines trimmed, cut to
    /// `maxNoteLength` characters (and trimmed again at the cut), nil when
    /// nothing is left.
    public static func normalizedNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(trimmed.prefix(maxNoteLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? nil : cut
    }
}
