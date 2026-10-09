import Testing

@testable import DriveLogger

@Suite("FollowController")
struct MapFollowTests {
    @Test("Camera settling alone never turns Following off")
    func settleKeepsFollowing() {
        var c = FollowController()
        for t in stride(from: 0.0, to: 60, by: 1) { c.cameraSettled(at: t) }
        #expect(c.isFollowing)
        #expect(c.resumeDeadline == nil)
    }

    @Test("Gesture turns it off and it resumes at +8 s, not before")
    func gestureThenResume() {
        var c = FollowController()
        c.userGesture(at: 100)
        #expect(!c.isFollowing)
        #expect(c.resumeDeadline == 108)
        #expect(c.tick(now: 107.9) == false)
        #expect(!c.isFollowing)
        #expect(c.tick(now: 108) == true)
        #expect(c.isFollowing)
        #expect(c.resumeDeadline == nil)
    }

    @Test("Gesture or camera change during the countdown restarts it")
    func restarts() {
        var c = FollowController()
        c.userGesture(at: 0)
        c.userGesture(at: 5)
        #expect(c.resumeDeadline == 13)
        c.cameraSettled(at: 9)
        #expect(c.resumeDeadline == 17)
        #expect(c.tick(now: 16.9) == false)
        #expect(c.tick(now: 17) == true)
    }

    @Test("A staged pin pauses, blocks resume, and the countdown starts after Confirm/Cancel")
    func pin() {
        var c = FollowController()
        c.pinStaged(true, at: 10)
        #expect(!c.isFollowing)
        #expect(c.resumeDeadline == nil)
        c.userGesture(at: 11)
        c.cameraSettled(at: 12)
        #expect(c.tick(now: 1000) == false)
        #expect(!c.isFollowing)
        c.pinStaged(false, at: 50)
        #expect(c.resumeDeadline == 58)
        #expect(c.tick(now: 57.9) == false)
        #expect(c.tick(now: 58) == true)
    }

    @Test("Pin staged after a gesture suspends the running countdown")
    func pinAfterGesture() {
        var c = FollowController()
        c.userGesture(at: 0)
        c.pinStaged(true, at: 3)
        #expect(c.tick(now: 9) == false)
        c.pinStaged(false, at: 20)
        #expect(c.resumeDeadline == 28)
    }

    @Test("Follow tap while a pin is staged does nothing")
    func tapDuringPin() {
        var c = FollowController()
        c.pinStaged(true, at: 0)
        c.followTapped(at: 1)
        #expect(!c.isFollowing)
        c.pinStaged(false, at: 2)
        #expect(c.resumeDeadline == 10)
    }

    @Test("Manual off never auto-resumes; tapping again resumes")
    func manualOff() {
        var c = FollowController()
        c.followTapped(at: 0)
        #expect(!c.isFollowing)
        #expect(c.resumeDeadline == nil)
        c.userGesture(at: 1)
        c.cameraSettled(at: 2)
        #expect(c.tick(now: 10_000) == false)
        #expect(!c.isFollowing)
        c.pinStaged(true, at: 3)
        c.pinStaged(false, at: 4)
        #expect(c.resumeDeadline == nil)
        c.followTapped(at: 5)
        #expect(c.isFollowing)
    }

    @Test("Tap while paused resumes immediately")
    func tapResumes() {
        var c = FollowController()
        c.userGesture(at: 0)
        c.followTapped(at: 2)
        #expect(c.isFollowing)
        #expect(c.resumeDeadline == nil)
    }

    @Test("Countdown value for the hint")
    func countdown() {
        var c = FollowController()
        #expect(c.countdownSeconds(now: 0) == nil)
        c.userGesture(at: 0)
        #expect(c.countdownSeconds(now: 0) == 8)
        #expect(c.countdownSeconds(now: 0.5) == 8)
        #expect(c.countdownSeconds(now: 1) == 7)
        #expect(c.countdownSeconds(now: 7.2) == 1)
        #expect(c.countdownSeconds(now: 9) == 1)
    }
}
