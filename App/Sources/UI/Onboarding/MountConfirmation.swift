import Foundation
import Observation

/// When the one-time in-car card "Phone mounted and won't move?" · "Mounted"
/// (UX-18 (2)) may show. Pure: the Navigate state and the OBD speed go in,
/// nothing is read from a clock or a sensor.
///
/// Shown only while all hold:
/// - not yet answered on this phone (`OnboardingStore.mountConfirmed`,
///   which the UX-1 checklist migration also sets);
/// - Navigate runs on OBD and calibration has ended: `NavigateState` is
///   `.running`. `.calibrating` hides it ("Hold still - calibrating" asks
///   for a still phone, so no tap is asked then). `.off` (no session, and
///   always `.off` while Record starts, runs or stops) and `.waitingForOBD`
///   (the link dropped) hide it too;
/// - the car stands: a fresh OBD speed of exactly 0 (`StationaryRule`, the
///   same rule heading-up holds still on). No speed reply yet, a stale one
///   or any speed above 0 hides it, so it is never shown in motion.
///
/// It only observes: it feeds nothing to the engine and does not change when
/// or how Navigate starts.
enum MountCardRule {
    static func isVisible(
        confirmed: Bool, navigate: NavigateState, obdKmh: Double?, replyUptime: Double?, now: Double
    ) -> Bool {
        guard !confirmed else { return false }
        switch navigate {
        case .running:
            return StationaryRule.isStopped(kmh: obdKmh, replyUptime: replyUptime, now: now)
        case .off, .calibrating, .waitingForOBD:
            return false
        }
    }
}

/// State of the in-car mount card. The map feed calls `update` with the
/// session's values (on each OBD speed change, on a Navigate state change,
/// and twice a second so a 0 ages out); the card's view reads `isVisible`
/// and calls `confirm()` on "Mounted".
///
/// While unanswered the card comes back at every stop of a Navigate run on
/// OBD and goes as soon as the car moves; once answered it never shows again
/// on this phone.
@MainActor
@Observable
final class MountConfirmationModel {
    /// Written only when it flips, so the twice-a-second update does not
    /// re-render the map.
    private(set) var isVisible: Bool
    /// How many times `isVisible` was assigned after init (a test sees the
    /// guard; `@Observable` would hide an equal write, M10.1-5).
    @ObservationIgnored private(set) var visibleWrites = 0

    @ObservationIgnored private let store: OnboardingStore
    /// DEBUG `-uiMountCard 1` (screenshots): visible whatever the inputs,
    /// until `confirm()`.
    @ObservationIgnored private var forced: Bool
    /// Cached `store.mountConfirmed`: `update` runs twice a second.
    @ObservationIgnored private var confirmed: Bool

    init(store: OnboardingStore = OnboardingStore(), forced: Bool = false) {
        self.store = store
        self.forced = forced
        confirmed = store.mountConfirmed
        isVisible = forced
    }

    /// - Parameters:
    ///   - navigate: `RecordingSession.navigateState`.
    ///   - obdKmh: `RecordingSession.live.obdSpeedKmh` (primary-ECU vehicle
    ///     speed; nil without a link and from a session's start until its
    ///     first reading).
    ///   - replyUptime: `RecordingSession.obdSpeedReplyUptime`.
    ///   - now: `RecordingSession.currentUptimeSeconds`.
    func update(navigate: NavigateState, obdKmh: Double?, replyUptime: Double?, now: Double) {
        guard !forced else { return }
        let next = MountCardRule.isVisible(
            confirmed: confirmed, navigate: navigate, obdKmh: obdKmh, replyUptime: replyUptime, now: now)
        if next != isVisible { setVisible(next) }
    }

    /// "Mounted": stored, hidden, never shown again on this phone.
    func confirm() {
        store.markMountConfirmed()
        confirmed = true
        forced = false
        if isVisible { setVisible(false) }
    }

    private func setVisible(_ value: Bool) {
        isVisible = value
        visibleWrites += 1
    }
}

extension MountConfirmationModel {
    /// `MapFeed`'s call: the session's own values, read (never observed) at
    /// the moment of the call.
    func update(session: RecordingSession) {
        update(
            navigate: session.navigateState, obdKmh: session.live.obdSpeedKmh,
            replyUptime: session.obdSpeedReplyUptime, now: session.currentUptimeSeconds)
    }
}
