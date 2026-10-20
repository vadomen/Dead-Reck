import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

@Suite("UX-1 part 2 / UX-18: first-launch cards, heading reset, Record from Settings", .serialized)
@MainActor
struct FirstLaunchAndTestDriveTests {
    func defaults() -> UserDefaults {
        let name = "firstlaunch-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func store(_ d: UserDefaults) -> OnboardingStore { OnboardingStore(defaults: d) }

    @Test("Fresh install shows the cards at card 1; seen once, the next launch does not")
    func freshShowsCards() {
        let d = defaults()
        let first = OnboardingModel(store: store(d))
        #expect(first.isPresented)
        #expect(first.mode == .firstRun)
        #expect(first.card == .howItWorks)
        #expect(!store(d).cardsSeen, "showing them stores nothing")
        first.skip()
        #expect(!OnboardingModel(store: store(d)).isPresented)
    }

    @Test("Next walks cards 1 to 4, the button reads Continue on the last, and Continue marks the cards seen")
    func nextThenContinue() {
        let d = defaults()
        let model = OnboardingModel(store: store(d))
        #expect(OnboardingCard.allCases.count == 4)
        for expected in OnboardingCard.allCases.dropLast() {
            #expect(model.card == expected && !model.isLast)
            #expect(model.primaryTitle == "Next")
            #expect(model.showsSkip, "Skip on every card")
            model.primary()
            #expect(model.isPresented && !store(d).cardsSeen, "not seen until the end")
        }
        #expect(model.card == .arrow && model.isLast)
        #expect(model.primaryTitle == "Continue")
        model.primary()
        #expect(!model.isPresented)
        #expect(store(d).cardsSeen)
    }

    @Test("Skip is hidden on the last card (it would equal Continue), shown on cards 1-3")
    func noSkipOnLastCard() {
        for card in 1...4 {
            let model = OnboardingModel(store: store(defaults()), forcedCard: card)
            #expect(model.showsSkip == (card != 4), "card \(card)")
        }
    }

    @Test("Skip on any card marks the cards seen and closes them")
    func skipAnywhere() {
        for card in 1...4 {
            let d = defaults()
            let model = OnboardingModel(store: store(d), forcedCard: card)
            #expect(model.card.number == card)
            model.skip()
            #expect(!model.isPresented)
            #expect(store(d).cardsSeen)
        }
    }

    @Test("Seen cards are not shown; a legacy confirmed checklist counts as seen; nothing ever writes the legacy key")
    func seenAndLegacy() {
        let seen = defaults()
        store(seen).markCardsSeen()
        #expect(!OnboardingModel(store: store(seen)).isPresented)

        let legacy = defaults()
        legacy.set(true, forKey: OnboardingStore.legacyChecklistKey)
        #expect(!OnboardingModel(store: store(legacy)).isPresented, "the old checklist was confirmed: no cards")
        #expect(MountConfirmationModel(store: store(legacy)).isVisible == false)
        #expect(store(legacy).mountConfirmed, "and no in-car card")

        // A fresh install going through the whole flow never writes the legacy key.
        let fresh = defaults()
        let model = OnboardingModel(store: store(fresh))
        model.skip()
        OnboardingModel(store: store(fresh), forcedCard: 4).primary()
        MountConfirmationModel(store: store(fresh)).confirm()
        #expect(fresh.object(forKey: OnboardingStore.legacyChecklistKey) == nil)
    }

    @Test("The debug override opens at that card even when seen; out-of-range values are ignored")
    func forcedCard() {
        let d = defaults()
        store(d).markCardsSeen()
        let model = OnboardingModel(store: store(d), forcedCard: 3)
        #expect(model.isPresented && model.card == .mount)
        #expect(!OnboardingModel(store: store(d), forcedCard: 0).isPresented)
        #expect(!OnboardingModel(store: store(d), forcedCard: 5).isPresented)
    }

    @Test("Review (Settings): from card 1, Next then Done, no Skip, never touches the store")
    func review() {
        let d = defaults()
        let model = OnboardingModel(mode: .review, store: store(d))
        #expect(!model.isPresented)
        model.page = 2
        model.show()
        #expect(model.isPresented && model.card == .howItWorks)
        #expect(!model.showsSkip)
        model.skip()
        #expect(model.isPresented, "no Skip in review")
        model.primary(); model.primary(); model.primary()
        #expect(model.isLast && model.primaryTitle == "Done")
        model.primary()
        #expect(!model.isPresented)
        #expect(!store(d).cardsSeen && !store(d).mountConfirmed)
        #expect(d.object(forKey: OnboardingStore.cardsSeenKey) == nil)
    }

    @Test("The maps step is sequenced after the cards: the root's rule is cards-not-presented and maps-presented")
    func mapsAfterCards() {
        let d = defaults()
        let cards = OnboardingModel(store: store(d))
        func mapsCoverShows(mapsPresented: Bool) -> Bool { !cards.isPresented && mapsPresented }
        #expect(!mapsCoverShows(mapsPresented: true), "never on top of the cards")
        cards.skip()
        #expect(mapsCoverShows(mapsPresented: true), "straight to the maps step after Skip")
        #expect(!mapsCoverShows(mapsPresented: false))
    }

    @Test("Card wording: fixed texts, no advice to touch the phone while moving, the vehicles link is on the site")
    func cardText() {
        #expect(OnboardingCard.allCases.map(\.title) == [
            "How FuGPS works", "Connect your adapter", "Mount the phone", "Getting the arrow fast"])
        #expect(OnboardingText.vehiclesURL.absoluteString == "https://fugps.pages.dev/vehicles.html")
        #expect(OnboardingText.position(.mount) == "Card 3 of 4")
        #expect(OnboardingText.driverAttention == "Don't use the phone while driving. Set it up before you set off.")
    }

    @Test("It is separate from Record's per-drive checklist")
    func separateFromRecord() {
        let d = defaults()
        OnboardingModel(store: store(d)).skip()
        // Record's store keeps only notes, and its checklist is still incomplete.
        #expect(ChecklistStore(defaults: d).load().isComplete == false)
    }

    @Test("Heading resets on a new recording and on a new Navigate session, not on the same run or before any")
    func headingResetKey() {
        let a = URL(fileURLWithPath: "/tmp/a.jsonl.gz")
        let b = URL(fileURLWithPath: "/tmp/b.jsonl.gz")
        let nav1 = MapRunKey(file: nil, run: 1)
        let nav2 = MapRunKey(file: nil, run: 3)
        #expect(HeadingReset.isNewRun(from: nil, to: nav1), "first Navigate session")
        #expect(HeadingReset.isNewRun(from: nav1, to: nav2), "Navigate, then another Navigate session")
        #expect(HeadingReset.isNewRun(from: nav1, to: MapRunKey(file: a, run: 2)), "Navigate, then Record")
        #expect(HeadingReset.isNewRun(from: MapRunKey(file: a, run: 2), to: MapRunKey(file: b, run: 4)))
        #expect(HeadingReset.isNewRun(from: MapRunKey(file: a, run: 2), to: nav2), "Record, then Navigate")
        #expect(HeadingReset.isNewRun(from: MapRunKey(file: a, run: nil), to: MapRunKey(file: b, run: nil)), "file alone")
        #expect(!HeadingReset.isNewRun(from: nav1, to: nav1), "a reconnect keeps the session")
        #expect(!HeadingReset.isNewRun(from: nav1, to: nil))
        #expect(!HeadingReset.isNewRun(from: nil, to: MapRunKey(file: nil, run: nil)))
    }

    @Test("The model's run key follows ingest: Navigate runs and recordings each give a new key")
    func modelRunKey() {
        let model = MapViewModel()
        #expect(model.runKey == MapRunKey(file: nil, run: nil))
        model.ingest(nil, file: nil, run: 1, isActive: true)
        let first = model.runKey
        #expect(first == MapRunKey(file: nil, run: 1))
        model.ingest(nil, file: nil, run: 1, isActive: true)
        #expect(model.runKey == first)
        model.ingest(nil, file: nil, run: 2, isActive: true)
        #expect(HeadingReset.isNewRun(from: first, to: model.runKey))
        let file = URL(fileURLWithPath: "/tmp/r.jsonl.gz")
        let before = model.runKey
        model.ingest(nil, file: file, run: 3, isActive: true)
        #expect(HeadingReset.isNewRun(from: before, to: model.runKey))
    }

    @Test("Test drive: Start from Settings (the Record view model) shows the map's indicator; Stop from the map ends it and the indicator goes")
    func startFromSettingsStopFromMap() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        let session = RecordingFixtures.session(link: link, store: scratch.store)
        let d = defaults()
        let model = RecordingViewModel(
            session: session, link: link, sources: [], simulatedSensors: false, store: ChecklistStore(defaults: d))
        #expect(MapRecordingControl.make(state: session.state, elapsed: 0) == .none, "no Start on the map")

        model.checklist.mountConfirmed = true
        model.checklist.orientationConfirmed = true
        await model.start()
        #expect(session.state == .recording || session.state == .calibrating)
        let control = MapRecordingControl.make(state: session.state, elapsed: session.live.elapsed)
        guard case .indicator = control else {
            Issue.record("expected the red indicator, got \(control)")
            return
        }
        var stop = StopConfirmation()
        stop.request()
        #expect(stop.isPending, "a tap on the indicator only asks")
        #expect(session.state != .idle)
        // The dialog's destructive button: the map's onStop is `session.stop()`.
        await session.stop()
        stop.cancel()
        #expect(session.state == .idle)
        #expect(MapRecordingControl.make(state: session.state, elapsed: 0) == .none)
    }

    @Test("The session says when Navigate began, for the countdown, and clears it at the end")
    func navigateStartedAt() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        #expect(session.navigateStartedAt == nil)
        #expect(session.navigateTimings == nil)
        let config = NavigateConfiguration(stillCalibration: .seconds(30), autoStopAfter: .seconds(60))
        let before = ContinuousClock.now
        session.enableNavigate(config)
        #expect(session.navigateTimings == config)
        #expect(session.navigateState == .calibrating)
        let started = try #require(session.navigateStartedAt)
        #expect(started >= before && started <= .now)
        session.disableNavigate()
        #expect(session.navigateState == .off)
        #expect(session.navigateStartedAt == nil)
    }

    @Test("R61.1-1: the map's loop task restarts when the estimate becomes visible (OBD connects after the app opened)")
    func loopKeyFollowsShowsEstimate() {
        let noOBD = NavigateStatus.make(
            navigate: .off, recording: .idle, startedAt: nil, timings: NavigateConfiguration(), now: .now)
        let running = NavigateStatus.make(
            navigate: .running, recording: .idle, startedAt: nil, timings: NavigateConfiguration(), now: .now)
        let before = MapLoopKey(isLive: true, showsEstimate: noOBD.showsEstimate)
        let after = MapLoopKey(isLive: true, showsEstimate: running.showsEstimate)
        #expect(before != after, "keyed on isLive alone (the old wiring) the loop kept its no-estimate copy")
        #expect(before == MapLoopKey(isLive: true, showsEstimate: false))
        #expect(after == MapLoopKey(isLive: true, showsEstimate: true))
        #expect(after != MapLoopKey(isLive: false, showsEstimate: true))
    }
}
