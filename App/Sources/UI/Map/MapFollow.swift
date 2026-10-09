import Foundation
import SwiftUI

/// Seconds on a monotonic clock, for `FollowController`. Display/UI timing only.
enum FollowClock {
    static var now: Double { ProcessInfo.processInfo.systemUptime }
}

/// Decides when the map follows the car. Pure value type: time is passed in
/// (seconds, any monotonic base), so it is unit-testable.
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
    static let resumeDelay: Double = 8
    /// Pushes closer than this to the current deadline are ignored, so a drag
    /// delivering 60 events a second does not re-render the map 60 times a second.
    private static let minExtension = 0.25

    private enum Mode: Equatable, Sendable {
        case following
        /// Paused; `nil` deadline means resume is suspended (pin staged).
        case paused(deadline: Double?)
        case manualOff
    }

    private var mode: Mode
    private(set) var isPinStaged = false

    init(following: Bool = true) {
        mode = following ? .following : .manualOff
    }

    var isFollowing: Bool { mode == .following }

    /// When Following will come back on its own; nil if it will not.
    var resumeDeadline: Double? {
        guard !isPinStaged, case .paused(let deadline?) = mode else { return nil }
        return deadline
    }

    /// Whole seconds left for the "Re-centre in N s" hint (rounded up, at least 1).
    func countdownSeconds(now: Double) -> Int? {
        guard let deadline = resumeDeadline else { return nil }
        return max(1, Int((deadline - now).rounded(.up)))
    }

    /// A touch on the map: drag, pinch, rotate or double-tap.
    mutating func userGesture(at now: Double) {
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
    mutating func cameraSettled(at now: Double) {
        if case .paused = mode { push(now) }
    }

    /// A pin was staged or cleared (Confirm, Cancel, or cleared by Start).
    mutating func pinStaged(_ staged: Bool, at now: Double) {
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
    mutating func followTapped(at now: Double) {
        guard !isPinStaged else { return }
        mode = (mode == .following) ? .manualOff : .following
    }

    /// Call when the deadline may have passed. True when Following just resumed.
    @discardableResult
    mutating func tick(now: Double) -> Bool {
        guard let deadline = resumeDeadline, now >= deadline else { return false }
        mode = .following
        return true
    }

    private mutating func push(_ now: Double) {
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
