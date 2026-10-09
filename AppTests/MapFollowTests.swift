import Testing

@testable import DriveLogger

private let base = ContinuousClock.now
private func t(_ seconds: Double) -> ContinuousClock.Instant { base + .seconds(seconds) }

@Suite("FollowController")
struct MapFollowTests {
    @Test("Camera settling alone never turns Following off")
    func settleKeepsFollowing() {
        var c = FollowController()
        for s in stride(from: 0.0, to: 60, by: 1) { c.cameraSettled(at: t(s)) }
        #expect(c.isFollowing)
        #expect(c.resumeDeadline == nil)
    }

    @Test("Gesture turns it off and it resumes at +8 s, not before")
    func gestureThenResume() {
        var c = FollowController()
        c.userGesture(at: t(100))
        #expect(!c.isFollowing)
        #expect(c.resumeDeadline == t(108))
        let r253712 = c.tick(now: t(107.9))
        #expect(r253712 == false)
        #expect(!c.isFollowing)
        let r254068 = c.tick(now: t(108))
        #expect(r254068 == true)
        #expect(c.isFollowing)
        #expect(c.resumeDeadline == nil)
    }

    @Test("Gesture or camera change during the countdown restarts it")
    func restarts() {
        var c = FollowController()
        c.userGesture(at: t(0))
        c.userGesture(at: t(5))
        #expect(c.resumeDeadline == t(13))
        c.cameraSettled(at: t(9))
        #expect(c.resumeDeadline == t(17))
        let r16601 = c.tick(now: t(16.9))
        #expect(r16601 == false)
        let r546349 = c.tick(now: t(17))
        #expect(r546349 == true)
    }

    @Test("A staged pin pauses, blocks resume, and the countdown starts after Confirm/Cancel")
    func pin() {
        var c = FollowController()
        c.pinStaged(true, at: t(10))
        #expect(!c.isFollowing)
        #expect(c.resumeDeadline == nil)
        c.userGesture(at: t(11))
        c.cameraSettled(at: t(12))
        let r864774 = c.tick(now: t(1000))
        #expect(r864774 == false)
        #expect(!c.isFollowing)
        c.pinStaged(false, at: t(50))
        #expect(c.resumeDeadline == t(58))
        let r76699 = c.tick(now: t(57.9))
        #expect(r76699 == false)
        let r412589 = c.tick(now: t(58))
        #expect(r412589 == true)
    }

    @Test("Pin staged after a gesture suspends the running countdown")
    func pinAfterGesture() {
        var c = FollowController()
        c.userGesture(at: t(0))
        c.pinStaged(true, at: t(3))
        let r662678 = c.tick(now: t(9))
        #expect(r662678 == false)
        c.pinStaged(false, at: t(20))
        #expect(c.resumeDeadline == t(28))
    }

    @Test("Follow tap while a pin is staged does nothing")
    func tapDuringPin() {
        var c = FollowController()
        c.pinStaged(true, at: t(0))
        c.followTapped(at: t(1))
        #expect(!c.isFollowing)
        c.pinStaged(false, at: t(2))
        #expect(c.resumeDeadline == t(10))
    }

    @Test("Manual off never auto-resumes; tapping again resumes")
    func manualOff() {
        var c = FollowController()
        c.followTapped(at: t(0))
        #expect(!c.isFollowing)
        #expect(c.resumeDeadline == nil)
        c.userGesture(at: t(1))
        c.cameraSettled(at: t(2))
        let r856092 = c.tick(now: t(10_000))
        #expect(r856092 == false)
        #expect(!c.isFollowing)
        c.pinStaged(true, at: t(3))
        c.pinStaged(false, at: t(4))
        #expect(c.resumeDeadline == nil)
        c.followTapped(at: t(5))
        #expect(c.isFollowing)
    }

    @Test("Tap while paused resumes immediately")
    func tapResumes() {
        var c = FollowController()
        c.userGesture(at: t(0))
        c.followTapped(at: t(2))
        #expect(c.isFollowing)
        #expect(c.resumeDeadline == nil)
    }

    @Test("Countdown value for the hint")
    func countdown() {
        var c = FollowController()
        #expect(c.countdownSeconds(now: t(0)) == nil)
        c.userGesture(at: t(0))
        #expect(c.countdownSeconds(now: t(0)) == 8)
        #expect(c.countdownSeconds(now: t(0.5)) == 8)
        #expect(c.countdownSeconds(now: t(1)) == 7)
        #expect(c.countdownSeconds(now: t(7.2)) == 1)
        #expect(c.countdownSeconds(now: t(9)) == 1)
    }

    @Test("Coalescing: a gesture 0.1 s later keeps the deadline, 0.3 s later moves it")
    func coalescing() {
        var c = FollowController()
        c.userGesture(at: t(0))
        c.userGesture(at: t(0.1))
        #expect(c.resumeDeadline == t(8))
        c.userGesture(at: t(0.3))
        #expect(c.resumeDeadline == t(0.3) + .seconds(8))
    }

    @Test("Tick before the deadline is false; a later tick still resumes (retry)")
    func retry() {
        var c = FollowController()
        c.userGesture(at: t(0))
        let r409169 = c.tick(now: t(7.5))
        #expect(r409169 == false)
        #expect(c.resumeDeadline == t(8))
        let r962983 = c.tick(now: t(8.2))
        #expect(r962983 == true)
    }

    @Test("An overdue deadline on foreground resumes at once")
    func overdue() {
        var c = FollowController()
        c.userGesture(at: t(0))
        let r894387 = c.tick(now: t(500))
        #expect(r894387 == true)
        #expect(c.isFollowing)
        #expect(c.resumeDeadline == nil)
    }
}
