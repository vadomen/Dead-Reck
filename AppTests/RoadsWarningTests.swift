import DriveLoggerCore
import Testing

@testable import DriveLogger

@Suite("RoadsWarning")
struct RoadsWarningTests {
    typealias Outcome = NavSidecar.RoadsSelection.Outcome

    private func message(
        recording: Bool = true, scanned: Bool = true, verified: Int = 1, attached: Bool = false,
        outcome: Outcome? = nil
    ) -> String? {
        RoadsWarning.message(
            recording: recording, libraryScanned: scanned, verifiedPacks: verified,
            roadsAttached: attached, lastOutcome: outcome
        )
    }

    @Test func notRecordingShowsNothing() {
        #expect(message(recording: false, verified: 0, outcome: .noPacks) == nil)
        #expect(message(recording: false, outcome: .refused) == nil)
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
    }
}
