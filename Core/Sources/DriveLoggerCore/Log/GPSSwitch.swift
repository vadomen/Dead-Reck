import Foundation

/// `gpsSwitch` (format v4): the driver's "GPS off" switch, set to `on` at
/// the event's `t` (the tap, on the session clock).
///
/// The switch says whether the live navigator may use the reference GNSS
/// fixes; it never changes what is recorded. `location` rows keep being
/// written while the switch is off, exactly as before, so an analysis can
/// still compare the estimate against the fixes the navigator was not
/// given. GNSS stays reference/ground truth either way: this row is not a
/// position, a fix or a sensor reading, only the driver's instruction.
///
/// Every recording and every Navigate session starts with the switch on and
/// no row: the first row of a file is normally `on: false`. Rows are written
/// at each change, in tap order, so they are in `t` order among themselves.
/// A row that repeats the current state (a double tap racing the UI) is
/// legal and means nothing changed.
///
/// An on-disk type: every stored property name is a JSON key and part of
/// the format. `source` is stored as a `String` (like the other
/// vocabularies) so a value added by a later build still decodes and is
/// kept verbatim; `Source` produces the values this build writes.
public struct GPSSwitchSample: Hashable, Sendable, Codable {
    /// `true`: navigation may use GNSS fixes; `false`: the driver turned
    /// GPS off and the fixes are withheld from the navigator from `t` on.
    public var on: Bool
    /// Who set the switch (`Source` raw values; an open set).
    public var source: String

    public init(on: Bool, source: String) {
        self.on = on
        self.source = source
    }

    public init(on: Bool, source: Source) {
        self.init(on: on, source: source.rawValue)
    }

    /// `source` vocabulary. Raw values are on-disk strings: never rename
    /// them. Open set: a later build may add a value (an automatic jamming
    /// detector, say) without a version bump; readers keep unknown values.
    public enum Source: String, Hashable, Sendable, CaseIterable {
        /// The driver tapped the switch.
        case driver
    }
}
