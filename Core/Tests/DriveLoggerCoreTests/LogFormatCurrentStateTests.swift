import Foundation
import Testing

@testable import DriveLoggerCore

/// Assertions about the *current* format: newest version, complete sets of
/// kinds and vocabulary values. Unlike `LogFormatCompatibilityTests`, this
/// suite is expected to be edited whenever a version is added — that edit is
/// the reminder to add a frozen fixture and pin the new strings there.
@Suite("Log format current state")
struct LogFormatCurrentStateTests {
    @Test("New recordings are written in the current version, v6")
    func writesCurrentVersion() throws {
        let header = LogHeader(
            sessionID: LogFixtures.sessionID,
            clock: SessionClock(source: FixedUptimeSource(uptimeSeconds: 1)),
            app: LogFixtures.app,
            device: LogFixtures.device
        )
        #expect(LogFormatVersion.current == .v6)
        #expect(header.formatVersion == .current)

        let line = String(decoding: try LogCodec().line(for: header), as: UTF8.self)
        #expect(line.contains("\"formatVersion\":6"))
    }

    @Test("Every declared format version has a frozen fixture")
    func allVersionsHaveFixtures() {
        // A version added to the enum without a reader and a fixture is the
        // failure mode the compatibility invariant exists to prevent.
        #expect(LogFormatVersion.allCases == [.v1, .v2, .v3, .v4, .v5, .v6])
        #expect(LogFormatVersion.current == LogFormatVersion.allCases.max())
        #expect(!LogFormatCompatibilityTests.version1Recording.isEmpty)
        #expect(!LogFormatCompatibilityV2Tests.version2Recording.isEmpty)
        #expect(!LogFormatCompatibilityV3Tests.version3Recording.isEmpty)
        #expect(!LogFormatCompatibilityV4Tests.version4Recording.isEmpty)
        #expect(!LogFormatCompatibilityV5Tests.version5Recording.isEmpty)
        #expect(!LogFormatCompatibilityV6Tests.version6Recording.isEmpty)
    }

    @Test("The version after current is not declared, and a header with it is refused")
    func refusesNextVersion() throws {
        // Lives here, not in a frozen suite: "the next version" moves with
        // every bump. The newest fixture relabelled one version up must be
        // refused, not read with the current rules.
        let next = LogFormatVersion.current.rawValue + 1
        #expect(LogFormatVersion(rawValue: next) == nil)
        let newest = LogFormatCompatibilityV6Tests.version6Recording
        #expect(newest.contains("\"formatVersion\":\(LogFormatVersion.current.rawValue)"))
        let relabelled = newest.replacingOccurrences(
            of: "\"formatVersion\":\(LogFormatVersion.current.rawValue)", with: "\"formatVersion\":\(next)")
        #expect(throws: LogDecodingError.unsupportedFormatVersion(next)) {
            try LogCodec().document(from: Data(relabelled.utf8))
        }
    }

    @Test("Every kind and vocabulary value is pinned in a frozen suite")
    func everythingIsPinned() {
        // Raise these only after adding the new strings to the frozen suite of
        // the version that introduces them.
        #expect(LogEventKind.allCases.count == 16)
        #expect(LifecycleSample.Event.allCases.count == 15)
        // `stop` details; pinned with the low-disk prefixes in
        // `LifecycleDetailTests` (R3-4).
        #expect(LifecycleSample.StopReason.allCases.count == 2)
        #expect(ELMPhase.allCases.count == 5)
        #expect(ELMOutcome.allCases.count == 14)
        #expect(ELMState.allCases.count == 10)
        #expect(LinkSample.BLEState.allCases.count == 9)
        #expect(LinkSample.Layer.allCases.count == 2)
        // Pinned in `LogFormatCompatibilityV3Tests`.
        #expect(ManualFixSample.SpeedSource.allCases.count == 3)
        // Pinned in `LogFormatCompatibilityV4Tests`.
        #expect(GPSSwitchSample.Source.allCases.count == 1)
        // Pinned in `LogFormatCompatibilityV5Tests`.
        #expect(NavPriorSample.Source.allCases.count == 1)
        #expect(NavigationRestoreClass.allCases.count == 3)
    }
}
