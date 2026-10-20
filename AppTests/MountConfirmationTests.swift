import Foundation
import Testing

@testable import DriveLogger

@Suite("UX-18 (2): the one-time in-car mount card")
@MainActor
struct MountConfirmationTests {
    func defaults() -> UserDefaults {
        let name = "mountcard-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Uptime "now" for every update; a reply at `now` is fresh.
    let now = 1_000.0

    /// One feed tick: `kmh` from a reply `age` seconds old.
    func tick(_ model: MountConfirmationModel, _ navigate: NavigateState, kmh: Double?, age: Double = 0.1) {
        model.update(navigate: navigate, obdKmh: kmh, replyUptime: kmh == nil ? nil : now - age, now: now)
    }

    @Test("Shown at a stationary OBD Navigate start only once calibration has ended")
    func shownAtStationaryStart() {
        let model = MountConfirmationModel(store: OnboardingStore(defaults: defaults()))
        #expect(!model.isVisible, "nothing before the first update")
        // Navigate started: no speed reply of this session yet.
        tick(model, .calibrating, kmh: nil)
        #expect(!model.isVisible)
        tick(model, .calibrating, kmh: 0)
        #expect(!model.isVisible, "Hold still - calibrating: no tap is asked for")
        tick(model, .running, kmh: 0)
        #expect(model.isVisible, "calibration done, stationary")
        tick(model, .running, kmh: 12)
        #expect(!model.isVisible, "moving")
    }

    @Test("Calibration hides a visible card and the rule alone never offers it while calibrating")
    func calibratingHides() {
        let model = MountConfirmationModel(store: OnboardingStore(defaults: defaults()))
        tick(model, .running, kmh: 0)
        #expect(model.isVisible)
        tick(model, .calibrating, kmh: 0)
        #expect(!model.isVisible)
        #expect(!MountCardRule.isVisible(confirmed: false, navigate: .calibrating, obdKmh: 0, replyUptime: now, now: now))
    }

    @Test("Never while OBD speed is above 0, even at 1 km/h")
    func neverInMotion() {
        let model = MountConfirmationModel(store: OnboardingStore(defaults: defaults()))
        for kmh in [1.0, 5, 50, 130] {
            tick(model, .running, kmh: kmh)
            #expect(!model.isVisible, "\(kmh) km/h")
            tick(model, .calibrating, kmh: kmh)
            #expect(!model.isVisible, "\(kmh) km/h, calibrating")
        }
    }

    @Test("Hidden on movement, back at the next stop while unanswered")
    func hiddenOnMoveBackAtStop() {
        let model = MountConfirmationModel(store: OnboardingStore(defaults: defaults()))
        tick(model, .running, kmh: 0)
        #expect(model.isVisible)
        tick(model, .running, kmh: 3)
        #expect(!model.isVisible)
        tick(model, .running, kmh: 40)
        #expect(!model.isVisible)
        tick(model, .running, kmh: 0)
        #expect(model.isVisible)
    }

    @Test("Not shown in Record: Navigate is off while a recording runs")
    func notInRecord() {
        let model = MountConfirmationModel(store: OnboardingStore(defaults: defaults()))
        // `RecordingSession` keeps `navigateState` at `.off` while Record
        // starts, runs or stops, with live OBD speed still reported.
        tick(model, .off, kmh: 0)
        #expect(!model.isVisible)
        tick(model, .running, kmh: 0)
        #expect(model.isVisible)
        tick(model, .off, kmh: 0)
        #expect(!model.isVisible, "Record started: the Navigate session ended")
    }

    @Test("Not shown without OBD speed: none, stale, not finite, or OBD lost")
    func notWithoutOBDSpeed() {
        let model = MountConfirmationModel(store: OnboardingStore(defaults: defaults()))
        tick(model, .running, kmh: nil)
        #expect(!model.isVisible, "no reply")
        tick(model, .running, kmh: 0, age: 2.5)
        #expect(!model.isVisible, "a stale 0 is unknown, not stopped")
        model.update(navigate: .running, obdKmh: 0, replyUptime: nil, now: now)
        #expect(!model.isVisible, "a 0 with no reply time")
        tick(model, .running, kmh: .nan)
        #expect(!model.isVisible)
        tick(model, .running, kmh: 0)
        #expect(model.isVisible)
        tick(model, .waitingForOBD(since: .now), kmh: 0)
        #expect(!model.isVisible, "the link left polling")
        tick(model, .running, kmh: 0)
        #expect(model.isVisible)
        tick(model, .running, kmh: 0, age: 2.5)
        #expect(!model.isVisible, "the 0 aged out")
    }

    @Test("Hidden for good after Mounted, also on a new model instance")
    func confirmedNeverAgain() {
        let d = defaults()
        let model = MountConfirmationModel(store: OnboardingStore(defaults: d))
        tick(model, .running, kmh: 0)
        #expect(model.isVisible)
        model.confirm()
        #expect(!model.isVisible)
        #expect(OnboardingStore(defaults: d).mountConfirmed)
        tick(model, .running, kmh: 20)
        tick(model, .running, kmh: 0)
        #expect(!model.isVisible, "the next stop")

        let next = MountConfirmationModel(store: OnboardingStore(defaults: d))
        tick(next, .running, kmh: 0)
        #expect(!next.isVisible, "the next launch")
    }

    @Test("Not shown after the UX-1 checklist migration")
    func notAfterMigration() {
        let d = defaults()
        d.set(true, forKey: OnboardingStore.legacyChecklistKey)
        let model = MountConfirmationModel(store: OnboardingStore(defaults: d))
        tick(model, .running, kmh: 0)
        #expect(!model.isVisible)
    }

    @Test("The debug override shows it whatever the inputs; Mounted still hides and stores it")
    func forced() {
        let d = defaults()
        d.set(true, forKey: OnboardingStore.legacyChecklistKey)
        let model = MountConfirmationModel(store: OnboardingStore(defaults: d), forced: true)
        #expect(model.isVisible)
        tick(model, .off, kmh: nil)
        tick(model, .running, kmh: 50)
        #expect(model.isVisible)
        model.confirm()
        #expect(!model.isVisible)
        tick(model, .running, kmh: 0)
        #expect(!model.isVisible)
    }

    @Test("isVisible is assigned only when it flips (the guard, not @Observable's dedup)")
    func writesOnlyOnFlip() {
        let model = MountConfirmationModel(store: OnboardingStore(defaults: defaults()))
        tick(model, .running, kmh: 5)
        tick(model, .off, kmh: nil)
        #expect(model.visibleWrites == 0, "hidden to hidden")
        tick(model, .running, kmh: 0)
        #expect(model.visibleWrites == 1)
        tick(model, .running, kmh: 0)
        tick(model, .running, kmh: 0)
        #expect(model.visibleWrites == 1, "visible to visible")
        model.confirm()
        model.confirm()
        #expect(model.visibleWrites == 2)
    }

    @Test("The rule alone: answered hides it in every state")
    func ruleConfirmed() {
        for navigate: NavigateState in [.off, .calibrating, .running, .waitingForOBD(since: .now)] {
            #expect(!MountCardRule.isVisible(confirmed: true, navigate: navigate, obdKmh: 0, replyUptime: now, now: now))
        }
        #expect(MountCardRule.isVisible(confirmed: false, navigate: .running, obdKmh: 0, replyUptime: now, now: now))
    }

    @Test("On a real session: hidden until Navigate's first 0, gone on movement and in Record, back at the next Navigate stop, never after Mounted")
    func onSession() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let d = defaults()
        let rig = NavigateRig(store: scratch.store)
        let model = MountConfirmationModel(store: OnboardingStore(defaults: d))
        let base = NavigateRig.base
        await rig.connect(speed: 0)
        model.update(session: rig.session)
        #expect(!model.isVisible, "the link polls at 0, but Navigate is off")

        rig.session.enableNavigate(NavigateConfiguration(stillCalibration: .seconds(1), autoStopAfter: .seconds(600)))
        #expect(rig.session.navigateState == .calibrating)
        model.update(session: rig.session)
        #expect(!model.isVisible, "Navigate started: no speed reply of its own yet")
        rig.uptime.set(base + 0.1)
        await rig.send(InitScript.poll(seq: 30, speed: 0, at: base + 0.1))
        model.update(session: rig.session)
        #expect(!model.isVisible, "still calibrating: no tap asked for")
        #expect(await eventually(5) { rig.session.navigateState == .running })
        await rig.send(InitScript.poll(seq: 30, speed: 0, at: base + 0.1))
        model.update(session: rig.session)
        #expect(model.isVisible, "calibration done, stationary OBD Navigate")

        rig.uptime.set(base + 3)
        model.update(session: rig.session)
        #expect(!model.isVisible, "the 0 went stale")
        await rig.send(InitScript.poll(seq: 31, speed: 18, at: base + 3))
        model.update(session: rig.session)
        #expect(!model.isVisible, "moving")
        rig.uptime.set(base + 4)
        await rig.send(InitScript.poll(seq: 32, speed: 0, at: base + 4))
        model.update(session: rig.session)
        #expect(model.isVisible, "the next stop")

        // Record: Navigate is off while it runs, whatever the speed.
        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        #expect(rig.session.navigateState == .off)
        rig.uptime.set(base + 5)
        await rig.send(InitScript.poll(seq: 33, speed: 0, at: base + 5))
        #expect(rig.session.live.obdSpeedKmh == 0)
        model.update(session: rig.session)
        #expect(!model.isVisible, "not in Record")
        await rig.session.stop()

        // Back to Navigate, stopped: after its calibration shown again, then answered for good.
        #expect(rig.session.navigateState.isActive)
        #expect(await eventually(5) { rig.session.navigateState == .running })
        rig.uptime.set(base + 6)
        await rig.send(InitScript.poll(seq: 34, speed: 0, at: base + 6))
        model.update(session: rig.session)
        #expect(model.isVisible)
        model.confirm()
        #expect(!model.isVisible)
        rig.uptime.set(base + 7)
        await rig.send(InitScript.poll(seq: 35, speed: 0, at: base + 7))
        model.update(session: rig.session)
        #expect(!model.isVisible)
        #expect(OnboardingStore(defaults: d).mountConfirmed)
        rig.session.disableNavigate()
    }
}
