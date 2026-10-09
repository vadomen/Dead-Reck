import Foundation
import SwiftUI

/// Decides when the map follows the car. Pure value type: time is passed in
/// as `ContinuousClock.Instant`, the clock `Task.sleep` waits on (it keeps
/// counting while the device sleeps), so it is unit-testable and a deadline
/// can never be early relative to the sleep that waits for it.
///
/// Only a real touch gesture turns Following off (`userGesture`). Programmatic
/// camera writes never do; MapKit also reports "positioned by user" for
/// changes we did not make, which is why that flag is not used.
///
/// States: following; paused by a gesture (auto-resumes `resumeDelay` s after
/// the last gesture or camera change); manually off (Follow tapped while
/// following: never auto-resumes); or paused under a staged pin (camera stays
/// still, the countdown starts only after the pin is confirmed or cancelled).
struct FollowController: Equatable, Sendable {
    static let resumeDelay: Duration = .seconds(8)
    /// Pushes closer than this to the current deadline are ignored, so a drag
    /// delivering 60 events a second does not re-render the map 60 times a second.
    private static let minExtension: Duration = .milliseconds(250)

    private enum Mode: Equatable, Sendable {
        case following
        /// Paused; `nil` deadline means resume is suspended (pin staged).
        case paused(deadline: ContinuousClock.Instant?)
        case manualOff
    }

    private var mode: Mode
    private(set) var isPinStaged = false

    init(following: Bool = true) {
        mode = following ? .following : .manualOff
    }

    var isFollowing: Bool { mode == .following }

    /// When Following will come back on its own; nil if it will not.
    var resumeDeadline: ContinuousClock.Instant? {
        guard !isPinStaged, case .paused(let deadline?) = mode else { return nil }
        return deadline
    }

    /// Whole seconds left for the "Re-centre in N s" hint (rounded up, at least 1).
    func countdownSeconds(now: ContinuousClock.Instant) -> Int? {
        guard let deadline = resumeDeadline else { return nil }
        let d = (deadline - now).components
        let seconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
        return max(1, Int(seconds.rounded(.up)))
    }

    /// A touch on the map: drag, pinch, rotate or double-tap.
    mutating func userGesture(at now: ContinuousClock.Instant) {
        switch mode {
        case .following:
            mode = .paused(deadline: isPinStaged ? nil : now + Self.resumeDelay)
        case .paused:
            push(now)
        case .manualOff:
            break
        }
    }

    /// The camera changed. While following that is our own doing and is
    /// ignored; while paused only the user moves it (including pan inertia),
    /// so the countdown restarts.
    mutating func cameraSettled(at now: ContinuousClock.Instant) {
        if case .paused = mode { push(now) }
    }

    /// A pin was staged or cleared (Confirm, Cancel, or cleared by Start).
    mutating func pinStaged(_ staged: Bool, at now: ContinuousClock.Instant) {
        guard staged != isPinStaged else { return }
        isPinStaged = staged
        if staged {
            if mode == .following { mode = .paused(deadline: nil) }
        } else if case .paused = mode {
            mode = .paused(deadline: now + Self.resumeDelay)
        }
    }

    /// The Follow button. Paused: resume now. Following: off for good until
    /// tapped again. While a pin is staged it does nothing: the camera stays
    /// still under the pin and the pin's own countdown rules apply.
    mutating func followTapped(at now: ContinuousClock.Instant) {
        guard !isPinStaged else { return }
        mode = (mode == .following) ? .manualOff : .following
    }

    /// Call when the deadline may have passed. True when Following just resumed.
    @discardableResult
    mutating func tick(now: ContinuousClock.Instant) -> Bool {
        guard let deadline = resumeDeadline, now >= deadline else { return false }
        mode = .following
        return true
    }

    private mutating func push(_ now: ContinuousClock.Instant) {
        guard !isPinStaged else { return }
        let deadline = now + Self.resumeDelay
        if case .paused(let old?) = mode, deadline - old < Self.minExtension { return }
        mode = .paused(deadline: deadline)
    }
}

extension View {
    /// Touch-only gestures that mean "the user is moving the map". They run
    /// alongside the map's own recognisers; programmatic camera writes cannot
    /// fire them.
    func onMapUserGesture(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in action() })
            .simultaneousGesture(MagnifyGesture().onChanged { _ in action() })
            .simultaneousGesture(RotateGesture().onChanged { _ in action() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { action() })
    }
}
