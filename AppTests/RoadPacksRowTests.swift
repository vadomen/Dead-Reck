import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// The `roadPacks` lifecycle row: the result of the library scan that
// NavigationService starts at Start, written into the recording once, only
// while it is still running.

@Suite("roadPacks lifecycle row", .serialized)
@MainActor
struct RoadPacksRowTests {
    /// Records with `library` wired through a NavigationService, lets the
    /// scan settle, stops (after `beforeStop`'s work) and returns the
    /// `roadPacks` rows.
    func rows(library: RoadPackLibrary, scratch: ScratchStore, stopBeforeScan: Bool = false,
              release: (@Sendable () -> Void)? = nil) async throws -> [LifecycleSample] {
        let service = NavigationService(library: library)
        let session = RecordingFixtures.session(sources: [FakeSource()], store: scratch.store)
        session.onNavigationFeed = { service.start($0) }
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(session.currentFile)
        if stopBeforeScan {
            await session.stop()
            release?()
        }
        _ = await library.candidates()
        try await Task.sleep(for: .milliseconds(300))
        if !stopBeforeScan { await session.stop() }
        let (_, events, _) = try RecordingFixtures.read(url)
        return RecordingFixtures.lifecycle(events).map(\.sample).filter { $0.event == LifecycleSample.Event.roadPacks.rawValue }
    }

    func details(_ rows: [LifecycleSample]) -> [String?] { rows.map(\.detail) }

    @Test("No packs: one row, none installed")
    func noPacks() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = RoadPackLibrary(source: RoadPackLibrary.directorySource(dir), cacheURL: nil)
        #expect(details(try await rows(library: library, scratch: scratch)) == ["none installed"])
    }

    @Test("All packs verified: n found, n verified")
    func allVerified() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "b.roadpack", in: dir)
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "a.roadpack", in: dir)
        let library = RoadPackLibrary(source: RoadPackLibrary.directorySource(dir), cacheURL: nil)
        #expect(details(try await rows(library: library, scratch: scratch)) == ["2 found, 2 verified"])
    }

    @Test("One refused: the file and its reason are appended")
    func oneRefused() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try RoadPackFixture.data()
        try RoadPackFixture.write(good, named: "good.roadpack", in: dir)
        try RoadPackFixture.write(good.prefix(good.count / 2), named: "old.roadpack", in: dir)
        let library = RoadPackLibrary(source: RoadPackLibrary.directorySource(dir), cacheURL: nil)
        let found = details(try await rows(library: library, scratch: scratch))
        #expect(found.count == 1)
        let text = try #require(found.first ?? nil)
        #expect(text.hasPrefix("2 found, 1 verified; old.roadpack: ") && text.count > "2 found, 1 verified; old.roadpack: ".count)
    }

    @Test("A scan that finishes after Stop leaves no row")
    func noneAfterStop() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "a.roadpack", in: dir)
        let gate = DispatchSemaphore(value: 0)
        let urls = RoadPackLibrary.listing(dir)
        let slow = RoadPackLibrary(source: {
            _ = gate.wait(timeout: .now() + 20)
            gate.signal()
            return urls
        }, cacheURL: nil)
        let found = try await rows(library: slow, scratch: scratch, stopBeforeScan: true) { gate.signal() }
        #expect(found.isEmpty)
    }

    @Test("roadPacksDetail: sorted, deterministic")
    func detailText() {
        func pack(_ name: String, _ reason: String?) -> RoadPackLibrary.PackStatus {
            .init(name: name, verified: reason == nil, refusal: reason, sizeBytes: nil, osmTimestamp: nil,
                  hashPrefix: nil, cacheHit: false, verifySeconds: nil)
        }
        #expect(RoadPackLibrary.roadPacksDetail([]) == "none installed")
        #expect(RoadPackLibrary.roadPacksDetail([pack("z.roadpack", "bad hash"), pack("a.roadpack", nil), pack("m.roadpack", "old")])
                == "3 found, 1 verified; m.roadpack: old; z.roadpack: bad hash")
        // N3.4: packs marked for removal and inbox refusals follow the
        // counts and are not counted.
        var pending = pack("b-00000000000000bb.roadpack", RoadPackLibrary.removalPendingText)
        pending.pendingRemoval = true
        var inbox = pack("x.roadpack", "bad magic")
        inbox.inInbox = true
        #expect(RoadPackLibrary.roadPacksDetail([inbox, pending, pack("a.roadpack", nil)])
                == "1 found, 1 verified; b-00000000000000bb.roadpack: removal pending (after restart); inbox x.roadpack: bad magic")
        #expect(RoadPackLibrary.roadPacksDetail([inbox, pending])
                == "none installed; b-00000000000000bb.roadpack: removal pending (after restart); inbox x.roadpack: bad magic")
    }
}
