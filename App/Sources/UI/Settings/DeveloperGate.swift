import Foundation
import Observation

/// Hides the developer diagnostics in Release (item 7 of UX-8's prompt):
/// always shown in DEBUG; in Release shown after 7 taps on the Version row,
/// and hidden again by 7 more. The choice is kept per install.
///
/// The counter is pure: taps must be consecutive, each within `window` of
/// the previous; a slow tap starts again at 1.
struct TapCounter: Equatable, Sendable {
    static let requiredTaps = 7
    static let window: TimeInterval = 1.5

    private(set) var count = 0
    private var last: Date?

    /// Registers a tap at `time`; true when it completes a run of 7 (the
    /// counter then starts over).
    mutating func tap(at time: Date) -> Bool {
        if let last, time.timeIntervalSince(last) <= Self.window, time >= last {
            count += 1
        } else {
            count = 1
        }
        last = time
        if count >= Self.requiredTaps {
            count = 0
            last = nil
            return true
        }
        return false
    }
}

/// Whether Settings shows the developer rows, and the Version-row gate.
@MainActor
@Observable
final class DeveloperGate {
    static let defaultsKey = "settings.developerDiagnostics"

    private(set) var unlocked: Bool
    /// "Developer diagnostics shown/hidden", set by the 7th tap.
    private(set) var toast: String?
    @ObservationIgnored private let isDebug: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var counter = TapCounter()

    init(isDebug: Bool = DeveloperGate.buildIsDebug, defaults: UserDefaults = .standard) {
        self.isDebug = isDebug
        self.defaults = defaults
        unlocked = defaults.bool(forKey: Self.defaultsKey)
    }

    static var buildIsDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// DEBUG always; Release once unlocked.
    var showsDiagnostics: Bool { isDebug || unlocked }

    /// A tap on the Version row. In DEBUG the rows are always shown, so taps
    /// do nothing.
    func tapVersion(at time: Date = Date()) {
        guard !isDebug else { return }
        guard counter.tap(at: time) else { return }
        unlocked.toggle()
        defaults.set(unlocked, forKey: Self.defaultsKey)
        toast = unlocked ? "Developer diagnostics shown" : "Developer diagnostics hidden"
    }

    func dismissToast() { toast = nil }
}
