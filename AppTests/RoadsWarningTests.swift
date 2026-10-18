import DriveLoggerCore
import Testing

@testable import DriveLogger

@Suite("RoadsWarning")
struct RoadsWarningTests {
    typealias Outcome = NavSidecar.RoadsSelection.Outcome

    private func message(
        active: Bool = true, scanned: Bool = true, verified: Int = 1, attached: Bool = false,
        outcome: Outcome? = nil
    ) -> String? {
        RoadsWarning.message(
            active: active, libraryScanned: scanned, verifiedPacks: verified,
            roadsAttached: attached, lastOutcome: outcome
        )
    }

    @Test func notRecordingShowsNothing() {
        #expect(message(active: false, verified: 0, outcome: .noPacks) == nil)
        #expect(message(active: false, outcome: .refused) == nil)
    }

    @Test func attachedRoadsShowNothing() {
        #expect(message(verified: 0, attached: true, outcome: .selected) == nil)
        #expect(message(attached: true, outcome: .noneCovering) == nil)
    }

    @Test func emptyLibraryAfterScanShowsAtOnce() {
        #expect(message(scanned: true, verified: 0, outcome: nil) == RoadsWarning.noPacks)
    }

    @Test func emptyLibraryBeforeScanShowsNothing() {
        #expect(message(scanned: false, verified: 0, outcome: nil) == nil)
    }

    @Test func noPacksOutcome() {
        #expect(message(outcome: .noPacks) == RoadsWarning.noPacks)
    }

    @Test func noneCoveringOutcome() {
        let text = message(outcome: .noneCovering)
        #expect(text == RoadsWarning.noneCovering)
        #expect(text?.contains("\n") == false)
    }

    @Test func refusedOutcome() {
        #expect(message(outcome: .refused) == RoadsWarning.refused)
    }

    @Test func unusableRequestSelectedUnfinishedShowNothing() {
        #expect(message(outcome: .unusableRequest) == nil)
        #expect(message(outcome: .selected) == nil)
        #expect(message(outcome: .unfinished) == nil)
    }

    @Test func noAttemptYetWithVerifiedPacksShowsNothing() {
        #expect(message(verified: 2, outcome: nil) == nil)
    }

    @Test func clearsAfterAttach() {
        #expect(message(outcome: .noneCovering) != nil)
        #expect(message(attached: true, outcome: .selected) == nil)
    }

    @Test func emptyLibraryWinsOverStaleOutcome() {
        #expect(message(verified: 0, outcome: .noneCovering) == RoadsWarning.noPacks)
    }

    @Test @MainActor func modelWritesOnlyChanges() async {
        let model = RoadsWarningModel(source: { RoadsWarning.noPacks })
        #expect(model.message == nil)
        await model.refresh()
        #expect(model.message == RoadsWarning.noPacks)
        #expect(model.messageWrites == 1)
        await model.refresh()
        await model.refresh()
        #expect(model.messageWrites == 1, "equal refreshes write nothing")
    }

    @Test @MainActor func modelWritesWhenTheLineChanges() async {
        actor Box { var line: String? = RoadsWarning.noPacks; func set(_ l: String?) { line = l } }
        let box = Box()
        let model = RoadsWarningModel(source: { await box.line })
        await model.refresh()
        await box.set(nil)
        await model.refresh()
        #expect(model.message == nil)
        #expect(model.messageWrites == 2)
    }
}
