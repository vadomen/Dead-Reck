import SwiftUI

/// The compact line on the map for Navigate mode (UX-1): what `navigateState`
/// means for the driver. Pure, in the style of `MapRecordingControl`: the
/// state, the timings and the instants go in, nothing is read from a clock.
enum NavigateStatus: Equatable {
    /// Nothing extra: Navigate runs (the dot and ellipse say it), or a
    /// recording is starting, running or ending and has its own display.
    case hidden
    /// The keep-still phase. `secondsLeft` counts down from
    /// `stillCalibration` (rounded up, so "5" shows first and "1" last);
    /// nil when the session did not say when it began.
    case calibrating(secondsLeft: Int?)
    /// The link left `polling`; `secondsLeft` until the auto-stop.
    case waitingForOBD(secondsLeft: Int)
    /// Navigate is off with no OBD (decision (d)): plain GPS only.
    case needsOBD

    /// `recording` is `RecordingSession.state`: Navigate is `.off` while a
    /// recording runs, and that must not read as "no OBD".
    static func make(
        navigate: NavigateState, recording: RecordingState,
        startedAt: ContinuousClock.Instant?, timings: NavigateConfiguration,
        now: ContinuousClock.Instant
    ) -> NavigateStatus {
        switch navigate {
        case .running:
            return .hidden
        case .calibrating:
            guard let startedAt else { return .calibrating(secondsLeft: nil) }
            return .calibrating(secondsLeft: secondsLeft(until: startedAt + timings.stillCalibration, now: now))
        case .waitingForOBD(let since):
            return .waitingForOBD(secondsLeft: secondsLeft(until: since + timings.autoStopAfter, now: now))
        case .off:
            switch recording {
            case .idle, .failed: return .needsOBD
            case .calibrating, .recording, .stopping: return .hidden
            }
        }
    }

    /// Whole seconds left until `deadline`, rounded up, never below 0.
    static func secondsLeft(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Int {
        let parts = (deadline - now).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return max(0, Int(seconds.rounded(.up)))
    }

    /// Whether the dead-reckoning dot and ellipse may be drawn: not without
    /// OBD (decision (d)), where only the plain GPS position shows.
    var showsEstimate: Bool { self != .needsOBD }

    var text: String? {
        switch self {
        case .hidden:
            nil
        case .calibrating:
            String(localized: "Hold still — calibrating")
        case .waitingForOBD:
            String(localized: "OBD lost — reconnecting")
        case .needsOBD:
            String(localized: "Connect OBD for navigation without GPS")
        }
    }

    /// The number on the right: the countdown, or time to auto-stop (`m:ss`).
    var detail: String? {
        switch self {
        case .calibrating(let left?):
            String(left)
        case .waitingForOBD(let left):
            String(localized: "Stops in \(DisplayFormat.elapsed(TimeInterval(left)))")
        case .hidden, .calibrating(nil), .needsOBD:
            nil
        }
    }

    var tone: Tone {
        switch self {
        case .hidden: .neutral
        case .calibrating: .caution
        case .waitingForOBD: .bad
        case .needsOBD: .caution
        }
    }

    var systemImage: String {
        switch self {
        case .hidden, .calibrating: "hand.raised.fill"
        case .waitingForOBD, .needsOBD: "cable.connector.slash"
        }
    }
}

/// The status line, bottom of the map above the controls. Its own view: it
/// alone ticks (once a second) for the countdown; model code never reads a
/// per-second `Date()`.
struct MapNavigateStatusLine: View {
    let session: RecordingSession

    var body: some View {
        let timings = session.navigateTimings ?? NavigateConfiguration()
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            NavigateStatusLabel(status: NavigateStatus.make(
                navigate: session.navigateState, recording: session.state,
                startedAt: session.navigateStartedAt, timings: timings, now: .now))
        }
    }
}

/// Plain-values presentation, for previews.
struct NavigateStatusLabel: View {
    let status: NavigateStatus

    var body: some View {
        if let text = status.text {
            // One line at the default Dynamic Type; when it no longer fits
            // (large sizes), the countdown drops under the text instead of
            // squeezing it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    icon
                    Text(text).font(.headline).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    detailView(font: .headline.weight(.bold).monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 10) {
                        icon
                        Text(text).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    detailView(font: .title3.weight(.bold).monospacedDigit())
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .hudSurface(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(status.tone.color, lineWidth: 2))
            // Like the offer and mount cards: it must not grow over the map at AX3+ (R67.1-5).
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityElement(children: .combine)
        }
    }

    private var icon: some View { Image(systemName: status.systemImage) }

    @ViewBuilder
    private func detailView(font: Font) -> some View {
        if let detail = status.detail {
            Text(detail).font(font)
        }
    }
}

#Preview("Calibrating") {
    NavigateStatusLabel(status: .calibrating(secondsLeft: 4)).padding()
}

#Preview("OBD lost") {
    NavigateStatusLabel(status: .waitingForOBD(secondsLeft: 272)).padding()
}

#Preview("Connect OBD") {
    NavigateStatusLabel(status: .needsOBD).padding()
}

#Preview("OBD lost, large type") {
    NavigateStatusLabel(status: .waitingForOBD(secondsLeft: 272))
        .padding()
        .dynamicTypeSize(.accessibility2)
}
