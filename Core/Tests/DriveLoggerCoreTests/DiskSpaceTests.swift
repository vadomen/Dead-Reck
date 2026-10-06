import Foundation
import Testing

@testable import DriveLoggerCore

@Suite("LowDiskSpaceMonitor")
struct LowDiskSpaceMonitorTests {
    // Round numbers keep the bands readable: low below 200, re-armed above 250.
    static let threshold: Int64 = 200
    static let hysteresis: Int64 = 50

    static func monitor() -> LowDiskSpaceMonitor {
        LowDiskSpaceMonitor(minimumFreeBytes: threshold, hysteresisBytes: hysteresis)
    }

    @Test("Reports once when free space first drops below the threshold")
    func reportsFirstCrossing() {
        var monitor = Self.monitor()
        #expect(monitor.observe(availableBytes: 1_000) == nil)
        #expect(monitor.observe(availableBytes: 300) == nil)
        #expect(monitor.observe(availableBytes: 199) == .lowDiskSpace(availableBytes: 199))
        #expect(monitor.isLow)
    }

    @Test("No repeat while staying below, even as the reading changes")
    func noRepeatWhileBelow() {
        var monitor = Self.monitor()
        #expect(monitor.observe(availableBytes: 150) == .lowDiskSpace(availableBytes: 150))
        // A different payload every flush must not produce a report every flush.
        for reading: Int64 in [149, 120, 180, 199, 10, 0] {
            #expect(monitor.observe(availableBytes: reading) == nil)
        }
    }

    @Test("A small recovery inside the hysteresis band does not re-arm")
    func noReportAfterRecoveryInsideBand() {
        var monitor = Self.monitor()
        #expect(monitor.observe(availableBytes: 190) != nil)
        // Back above the threshold, but not above threshold + hysteresis.
        #expect(monitor.observe(availableBytes: 230) == nil)
        #expect(monitor.observe(availableBytes: 190) == nil)
        #expect(monitor.isLow)
    }

    @Test("Re-reports after recovering above threshold + hysteresis and dropping again")
    func reReportsAfterFullRecovery() {
        var monitor = Self.monitor()
        #expect(monitor.observe(availableBytes: 190) == .lowDiskSpace(availableBytes: 190))
        #expect(monitor.observe(availableBytes: 251) == nil)
        #expect(!monitor.isLow)
        #expect(monitor.observe(availableBytes: 220) == nil)
        #expect(monitor.observe(availableBytes: 180) == .lowDiskSpace(availableBytes: 180))
    }

    @Test("Starting already below the threshold reports on the first observation")
    func reportsWhenStartingBelow() {
        var monitor = Self.monitor()
        #expect(!monitor.isLow)
        #expect(monitor.observe(availableBytes: 5) == .lowDiskSpace(availableBytes: 5))
        #expect(monitor.observe(availableBytes: 5) == nil)
    }

    @Test("Exactly at the threshold is not low; exactly at threshold + hysteresis does not re-arm")
    func boundaries() {
        var monitor = Self.monitor()
        // "Below" is strict.
        #expect(monitor.observe(availableBytes: Self.threshold) == nil)
        #expect(!monitor.isLow)
        #expect(monitor.observe(availableBytes: Self.threshold - 1) != nil)
        // Re-arming needs strictly more than threshold + hysteresis.
        #expect(monitor.observe(availableBytes: Self.threshold + Self.hysteresis) == nil)
        #expect(monitor.isLow)
        #expect(monitor.observe(availableBytes: Self.threshold - 1) == nil)
        #expect(monitor.observe(availableBytes: Self.threshold + Self.hysteresis + 1) == nil)
        #expect(!monitor.isLow)
        #expect(monitor.observe(availableBytes: Self.threshold - 1) != nil)
    }

    @Test("Default hysteresis is 50 MB")
    func defaultHysteresis() {
        let monitor = LowDiskSpaceMonitor(minimumFreeBytes: 200_000_000)
        #expect(monitor.hysteresisBytes == 50_000_000)
        #expect(LowDiskSpaceMonitor.defaultHysteresisBytes == 50_000_000)
    }

    @Test("A threshold near Int64.max does not overflow the re-arm level")
    func saturatesRearmLevel() {
        var monitor = LowDiskSpaceMonitor(minimumFreeBytes: .max - 10, hysteresisBytes: 100)
        #expect(monitor.observe(availableBytes: 0) != nil)
        // Re-arm level saturates at Int64.max, which no reading exceeds.
        #expect(monitor.observe(availableBytes: .max) == nil)
        #expect(monitor.isLow)
    }
}

@Suite("VolumeDiskSpaceProvider")
struct VolumeDiskSpaceProviderTests {
    @Test("Reports positive free space for a temporary directory")
    func positiveForTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
        let bytes = try VolumeDiskSpaceProvider().availableBytes(for: directory)
        #expect(bytes > 0)
    }

    @Test("Resolves a not-yet-created file to its directory")
    func resolvesMissingFileToDirectory() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).jsonl.gz")
        let bytes = try VolumeDiskSpaceProvider().availableBytes(for: missing)
        #expect(bytes > 0)
    }
}
