import Foundation

/// `manualFix` (format v3): a position the driver confirmed on the map — "I'm
/// here" — as ground truth for evaluating dead reckoning offline, above all
/// where GNSS is jammed or absent (tunnels).
///
/// An on-disk type: every stored property name is a JSON key and part of the
/// format. The event's `t` is the confirm time on the session clock.
/// `speedSource` is stored as a `String` (like the other vocabularies) so a
/// value added by a later build still decodes; `SpeedSource` produces it.
///
/// The speed fields record *why the fix was allowed* (`ManualFixGate`): a pin
/// placed while driving fast is not ground truth, so the recorder refuses one
/// above `ManualFixGate.maxSpeedKmh`.
public struct ManualFixSample: Hashable, Sendable, Codable {
    /// Degrees, WGS 84, of the confirmed pin.
    public var latitude: Double
    /// Degrees, WGS 84, of the confirmed pin.
    public var longitude: Double
    /// When the long-press that placed the pin began, on the session clock.
    /// `t − pressedT` is how long the driver took to confirm.
    public var pressedT: MonotonicTimestamp
    /// Visible map span at confirm, in metres: how precisely the pin could
    /// be placed. Absent when the UI did not report one.
    public var mapSpanM: Double?
    /// Last vehicle speed from the primary ECU (`7E8`) at confirm, km/h.
    /// Absent when the link had none (not connected, or no reply yet).
    /// Recorded even when it was too old to gate (`speedSource` then is not
    /// `obd`).
    public var obdSpeedKmh: Double?
    /// When that OBD reply arrived, on the session clock: the `t` of its
    /// `obd` row. `t − obdSpeedT` is how old the speed was. Present exactly
    /// when `obdSpeedKmh` is.
    public var obdSpeedT: MonotonicTimestamp?
    /// Speed of the latest reference GNSS fix at confirm, km/h, whenever that
    /// fix reported a speed (`speed ≥ 0`), however old or inaccurate.
    /// **Reference only**, recorded for analysis; it is the gate speed only
    /// when `speedSource` is `gps`.
    public var gpsSpeedKmh: Double?
    /// Which speed the gate used: `obd`, `gps` or `unknown`
    /// (`SpeedSource` raw values).
    public var speedSource: String
    /// The speed the gate compared with its limit, km/h. Absent when
    /// `speedSource` is `unknown`.
    public var gateSpeedKmh: Double?
    /// Optional free text from the driver: trimmed, at most
    /// `maxNoteLength` characters, absent when empty.
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
        /// Neither was usable. The fix is still allowed.
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
