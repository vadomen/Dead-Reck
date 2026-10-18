import Foundation
import Testing

@testable import DriveLogger

@Suite("Navigate status line (UX-1 part 2)")
struct MapNavigateStatusTests {
    let timings = NavigateConfiguration()  // 5 s still, 300 s auto-stop
    let t0 = ContinuousClock.Instant.now

    func status(
        _ navigate: NavigateState, recording: RecordingState = .idle,
        startedAt: ContinuousClock.Instant? = nil, after: Duration = .zero
    ) -> NavigateStatus {
        NavigateStatus.make(
            navigate: navigate, recording: recording, startedAt: startedAt, timings: timings, now: t0 + after)
    }

    @Test("Calibrating counts down from 5, rounded up, to 0; never negative")
    func calibratingCountdown() {
        func left(_ after: Duration) -> NavigateStatus { status(.calibrating, startedAt: t0, after: after) }
        #expect(left(.zero) == .calibrating(secondsLeft: 5))
        #expect(left(.milliseconds(1)) == .calibrating(secondsLeft: 5))
        #expect(left(.seconds(1)) == .calibrating(secondsLeft: 4))
        #expect(left(.milliseconds(4_200)) == .calibrating(secondsLeft: 1))
        #expect(left(.milliseconds(4_999)) == .calibrating(secondsLeft: 1))
        #expect(left(.seconds(5)) == .calibrating(secondsLeft: 0))
        #expect(left(.seconds(9)) == .calibrating(secondsLeft: 0))
    }

    @Test("Calibrating without a start instant has text but no number; detail is the number")
    func calibratingText() {
        let none = status(.calibrating)
        #expect(none == .calibrating(secondsLeft: nil))
        #expect(none.detail == nil)
        #expect(none.text == "Hold still — calibrating")
        #expect(status(.calibrating, startedAt: t0, after: .seconds(1)).detail == "4")
    }

    @Test("Running shows nothing extra")
    func running() {
        #expect(status(.running) == .hidden)
        #expect(status(.running).text == nil)
        #expect(status(.running).detail == nil)
        #expect(status(.running).showsEstimate)
    }

    @Test("Waiting for OBD shows the time left until the 5 min auto-stop")
    func waiting() {
        func left(_ after: Duration) -> NavigateStatus { status(.waitingForOBD(since: t0), after: after) }
        #expect(left(.zero) == .waitingForOBD(secondsLeft: 300))
        #expect(left(.milliseconds(500)) == .waitingForOBD(secondsLeft: 300))
        #expect(left(.seconds(28)) == .waitingForOBD(secondsLeft: 272))
        #expect(left(.milliseconds(299_001)) == .waitingForOBD(secondsLeft: 1))
        #expect(left(.seconds(300)) == .waitingForOBD(secondsLeft: 0))
        #expect(left(.seconds(400)) == .waitingForOBD(secondsLeft: 0))
        #expect(left(.seconds(28)).text == "OBD lost — reconnecting")
        #expect(left(.seconds(28)).detail == "Stops in 4:32")
        #expect(left(.seconds(28)).showsEstimate)
        #expect(left(.seconds(28)).tone == .bad)
    }

    @Test("Off with no recording asks for OBD: GPS only, no estimate")
    func needsOBD() {
        for recording in [RecordingState.idle, .failed(reason: "disk full", unwrittenEvents: 0)] {
            let s = status(.off, recording: recording)
            #expect(s == .needsOBD)
            #expect(s.text == "Connect OBD for navigation without GPS")
            #expect(!s.showsEstimate)
        }
    }

    @Test("While a recording starts, runs or stops, off never claims Connect OBD")
    func recordingOwnsTheScreen() {
        for recording in [RecordingState.calibrating, .recording, .stopping] {
            let s = status(.off, recording: recording)
            #expect(s == .hidden)
            #expect(s.text == nil)
            #expect(s.showsEstimate)
        }
    }

    @Test("Session timings other than the defaults are used")
    func customTimings() {
        let quick = NavigateConfiguration(stillCalibration: .seconds(2), autoStopAfter: .seconds(10))
        #expect(NavigateStatus.make(navigate: .calibrating, recording: .idle, startedAt: t0, timings: quick, now: t0)
            == .calibrating(secondsLeft: 2))
        #expect(NavigateStatus.make(navigate: .waitingForOBD(since: t0), recording: .idle, startedAt: nil, timings: quick, now: t0 + .seconds(4))
            == .waitingForOBD(secondsLeft: 6))
    }
}
