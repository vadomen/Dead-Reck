import Foundation
import Testing

@testable import DriveLoggerCore

@Suite("LowDiskSpaceMonitor")
struct LowDiskSpaceMonitorTests {
    // Round numbers keep the bands readable: below under 200, re-armed above 250.
    static let threshold: Int64 = 200
    static let hysteresis: Int64 = 50

    static func monitor() -> LowDiskSpaceMonitor {
        LowDiskSpaceMonitor(thresholdBytes: threshold, hysteresisBytes: hysteresis)
    }

    @Test("Reports once when free space first drops below the threshold")
    func reportsFirstCrossing() {
        var monitor = Self.monitor()
        #expect(monitor.observe(availableBytes: 1_000) == false)
        #expect(monitor.observe(availableBytes: 300) == false)
        #expect(monitor.observe(availableBytes: 199) == true)
        #expect(monitor.isBelow)
    }

    @Test("No repeat while staying below, even as the reading changes")
    func noRepeatWhileBelow() {
        var monitor = Self.monitor()
        #expect(monitor.observe(availableBytes: 150) == true)
        // A different reading every flush must not produce a report every flush.
        for reading: Int64 in [149, 120, 180, 199, 10, 0] {
            #expect(monitor.observe(availableBytes: reading) == false)
        }
    }

    @Test("A small recovery inside the hysteresis band does not re-arm")
    func noReportAfterRecoveryInsideBand() {
        var monitor = Self.monitor()
        #expect(monitor.observe(availableBytes: 190) == true)
        // Back above the threshold, but not above threshold + hysteresis.
        #expect(monitor.observe(availableBytes: 230) == false)
        #expect(monitor.observe(availableBytes: 190) == false)
        #expect(monitor.isBelow)
    }

    @Test("Re-reports after recovering above threshold + hysteresis and dropping again")
    func reReportsAfterFullRecovery() {
        var monitor = Self.monitor()
        #expect(monitor.observe(availableBytes: 190) == true)
        #expect(monitor.observe(availableBytes: 251) == false)
        #expect(!monitor.isBelow)
        #expect(monitor.observe(availableBytes: 220) == false)
        #expect(monitor.observe(availableBytes: 180) == true)
    }

    @Test("Starting already below the threshold reports on the first observation")
    func reportsWhenStartingBelow() {
        var monitor = Self.monitor()
        #expect(!monitor.isBelow)
        #expect(monitor.observe(availableBytes: 5) == true)
        #expect(monitor.observe(availableBytes: 5) == false)
    }

    @Test("Exactly at the threshold is not below; exactly at threshold + hysteresis does not re-arm")
    func boundaries() {
        var monitor = Self.monitor()
        // "Below" is strict.
        #expect(monitor.observe(availableBytes: Self.threshold) == false)
        #expect(!monitor.isBelow)
        #expect(monitor.observe(availableBytes: Self.threshold - 1) == true)
        // Re-arming needs strictly more than threshold + hysteresis.
        #expect(monitor.observe(availableBytes: Self.threshold + Self.hysteresis) == false)
        #expect(monitor.isBelow)
        #expect(monitor.observe(availableBytes: Self.threshold - 1) == false)
        #expect(monitor.observe(availableBytes: Self.threshold + Self.hysteresis + 1) == false)
        #expect(!monitor.isBelow)
        #expect(monitor.observe(availableBytes: Self.threshold - 1) == true)
    }

    @Test("Default hysteresis is 50 MB")
    func defaultHysteresis() {
        let monitor = LowDiskSpaceMonitor(thresholdBytes: 200_000_000)
        #expect(monitor.hysteresisBytes == 50_000_000)
        #expect(LowDiskSpaceMonitor.defaultHysteresisBytes == 50_000_000)
    }

    @Test("A threshold near Int64.max does not overflow the re-arm level")
    func saturatesRearmLevel() {
        var monitor = LowDiskSpaceMonitor(thresholdBytes: .max - 10, hysteresisBytes: 100)
        #expect(monitor.observe(availableBytes: 0) == true)
        // Re-arm level saturates at Int64.max, which no reading exceeds.
        #expect(monitor.observe(availableBytes: .max) == false)
        #expect(monitor.isBelow)
    }
}

/// Regression for R2-2: the "warn, then stop at a floor" policy. Before this
/// change `DiskSpacePolicy` and `DiskSpaceNotice` did not exist (this suite
/// failed to compile) and the writer had a single advisory threshold whose
/// consumer behaviour was contradictory.
@Suite("DiskSpacePolicy")
struct DiskSpacePolicyTests {
    // Bands: warning below 200 (re-arms above 250), floor below 50 (re-arms above 100).
    static let warning: Int64 = 200
    static let floor: Int64 = 50
    static let hysteresis: Int64 = 50

    static func policy() -> DiskSpacePolicy {
        DiskSpacePolicy(warningFreeBytes: warning, stopFreeBytes: floor, hysteresisBytes: hysteresis)
    }

    @Test("Defaults: warn below 200 MB, stop below 50 MB, 50 MB hysteresis")
    func defaults() {
        let policy = DiskSpacePolicy()
        #expect(policy.warningFreeBytes == 200_000_000)
        #expect(policy.stopFreeBytes == 50_000_000)
        #expect(DiskSpacePolicy.defaultWarningFreeBytes == 200_000_000)
        #expect(DiskSpacePolicy.defaultStopFreeBytes == 50_000_000)
        #expect(!policy.isLow)
        #expect(!policy.isCritical)
    }

    @Test("Crossing the warning threshold yields .low only")
    func warningCrossing() {
        var policy = Self.policy()
        #expect(policy.observe(availableBytes: 1_000) == [])
        #expect(policy.observe(availableBytes: Self.warning) == [])
        #expect(policy.observe(availableBytes: 199) == [.low(availableBytes: 199)])
        #expect(policy.isLow)
        #expect(!policy.isCritical)
        // Staying in the warning band reports nothing more.
        for reading: Int64 in [180, 120, 199, 51, Self.floor] {
            #expect(policy.observe(availableBytes: reading) == [])
        }
    }

    @Test("Continuing down past the floor yields .critical exactly once")
    func continuingPastFloor() {
        var policy = Self.policy()
        #expect(policy.observe(availableBytes: 150) == [.low(availableBytes: 150)])
        #expect(policy.observe(availableBytes: 49) == [.critical(availableBytes: 49)])
        #expect(policy.isCritical)
        for reading: Int64 in [48, 10, 0, 49, 30] {
            #expect(policy.observe(availableBytes: reading) == [])
        }
    }

    @Test("A single reading below both thresholds yields .low then .critical")
    func straightDropBelowBoth() {
        var policy = Self.policy()
        #expect(policy.observe(availableBytes: 500) == [])
        #expect(policy.observe(availableBytes: 10) == [.low(availableBytes: 10), .critical(availableBytes: 10)])
        #expect(policy.observe(availableBytes: 9) == [])
    }

    @Test("Starting below both thresholds reports both on the first observation")
    func startingBelowBoth() {
        var policy = Self.policy()
        #expect(policy.observe(availableBytes: 0) == [.low(availableBytes: 0), .critical(availableBytes: 0)])
    }

    @Test("The floor re-arms on its own hysteresis while the warning stays disarmed")
    func floorRearmsIndependently() {
        var policy = Self.policy()
        #expect(policy.observe(availableBytes: 40) == [.low(availableBytes: 40), .critical(availableBytes: 40)])
        // Exactly floor + hysteresis: neither re-arms.
        #expect(policy.observe(availableBytes: Self.floor + Self.hysteresis) == [])
        #expect(policy.isCritical)
        // Above floor + hysteresis but still below the warning threshold:
        // only the floor re-arms, silently.
        #expect(policy.observe(availableBytes: 150) == [])
        #expect(!policy.isCritical)
        #expect(policy.isLow)
        // Dropping below the floor again reports .critical alone; the warning
        // is still disarmed.
        #expect(policy.observe(availableBytes: 45) == [.critical(availableBytes: 45)])
    }

    @Test("The warning re-arms on its own hysteresis; the floor follows its own rule")
    func warningRearmsIndependently() {
        var policy = Self.policy()
        #expect(policy.observe(availableBytes: 100) == [.low(availableBytes: 100)])
        // Recovery inside the warning band's hysteresis does not re-arm.
        #expect(policy.observe(availableBytes: Self.warning + Self.hysteresis) == [])
        #expect(policy.isLow)
        #expect(policy.observe(availableBytes: 190) == [])
        // Strictly above warning + hysteresis re-arms, silently.
        #expect(policy.observe(availableBytes: Self.warning + Self.hysteresis + 1) == [])
        #expect(!policy.isLow)
        #expect(policy.observe(availableBytes: 190) == [.low(availableBytes: 190)])
    }

    @Test("A full recovery re-arms both; the next drop below both reports both again")
    func fullRecoveryRearmsBoth() {
        var policy = Self.policy()
        #expect(policy.observe(availableBytes: 0).count == 2)
        #expect(policy.observe(availableBytes: 1_000) == [])
        #expect(!policy.isLow)
        #expect(!policy.isCritical)
        #expect(policy.observe(availableBytes: 20) == [.low(availableBytes: 20), .critical(availableBytes: 20)])
    }

    @Test("Start is allowed at or above the warning threshold and refused strictly below it")
    func canStartBoundary() {
        #expect(DiskSpacePolicy.canStart(availableBytes: 1_000, warningFreeBytes: Self.warning))
        #expect(DiskSpacePolicy.canStart(availableBytes: Self.warning, warningFreeBytes: Self.warning))
        #expect(!DiskSpacePolicy.canStart(availableBytes: Self.warning - 1, warningFreeBytes: Self.warning))
        #expect(!DiskSpacePolicy.canStart(availableBytes: Self.floor, warningFreeBytes: Self.warning))
        #expect(!DiskSpacePolicy.canStart(availableBytes: 0, warningFreeBytes: Self.warning))
        // Default threshold is the writer's default warning threshold.
        #expect(DiskSpacePolicy.canStart(availableBytes: 200_000_000))
        #expect(!DiskSpacePolicy.canStart(availableBytes: 199_999_999))
    }

    @Test("Any reading that can start a recording does not trigger a notice")
    func canStartAgreesWithPolicy() {
        for reading: Int64 in [Self.warning, Self.warning + 1, 10_000] {
            var policy = Self.policy()
            #expect(DiskSpacePolicy.canStart(availableBytes: reading, warningFreeBytes: Self.warning))
            #expect(policy.observe(availableBytes: reading) == [])
        }
        var policy = Self.policy()
        #expect(!DiskSpacePolicy.canStart(availableBytes: Self.warning - 1, warningFreeBytes: Self.warning))
        #expect(policy.observe(availableBytes: Self.warning - 1) == [.low(availableBytes: Self.warning - 1)])
    }

    @Test("The floor just below the warning threshold is a valid configuration")
    func adjacentThresholdsAreValid() {
        var policy = DiskSpacePolicy(warningFreeBytes: 100, stopFreeBytes: 99, hysteresisBytes: 0)
        #expect(policy.observe(availableBytes: 99) == [.low(availableBytes: 99)])
        #expect(policy.observe(availableBytes: 98) == [.critical(availableBytes: 98)])
    }

    #if os(macOS)
    // `precondition(stopFreeBytes < warningFreeBytes)`: a floor at or above
    // the warning threshold would stop a drive without ever warning.
    @Test("A floor equal to the warning threshold traps")
    func floorEqualToWarningTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = DiskSpacePolicy(warningFreeBytes: 100, stopFreeBytes: 100)
        }
    }

    @Test("A floor above the warning threshold traps")
    func floorAboveWarningTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = DiskSpacePolicy(warningFreeBytes: 50, stopFreeBytes: 200)
        }
    }
    #endif
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

/// Regression for R2-1. `LogFileWriter` keeps one recording `URL` for the
/// whole drive and asks the provider for free space on every flush, from an
/// actor on the cooperative pool where no run loop ever turns. Foundation
/// caches resource values on a `URL` instance until the next run-loop turn,
/// so a provider that reads through the caller's instance returns the
/// start-of-drive value forever. This test reproduces exactly that: one URL
/// instance, two readings from an actor, real bytes written and synced in
/// between.
@Suite("VolumeDiskSpaceProvider freshness")
struct VolumeDiskSpaceProviderFreshnessTests {
    /// Mirrors the writer: holds one URL instance and the provider, reads off
    /// the main thread with no run loop.
    actor Reader {
        let url: URL
        let provider = VolumeDiskSpaceProvider()
        init(url: URL) { self.url = url }
        func read() throws -> Int64 { try provider.availableBytes(for: url) }
    }

    static let bytesToWrite = 512 * 1024 * 1024
    static let chunkSize = 8 * 1024 * 1024

    @Test("A second reading on the same URL instance reflects bytes written since the first")
    func secondReadingIsNotCached() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("diskspace-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        // The "recording" the writer would hold. It exists, so the provider
        // reads through this file's URL rather than its parent.
        let recording = directory.appendingPathComponent("drive.jsonl.gz")
        #expect(fileManager.createFile(atPath: recording.path, contents: Data("{}\n".utf8)))

        let reader = Reader(url: recording)
        let before = try await reader.read()

        // Fill a separate file with non-zero bytes (nothing a filesystem can
        // keep sparse) and force it to disk so the volume's counters move.
        let filler = directory.appendingPathComponent("filler.bin")
        #expect(fileManager.createFile(atPath: filler.path, contents: nil))
        let handle = try FileHandle(forWritingTo: filler)
        let chunk = Data(repeating: 0xA5, count: Self.chunkSize)
        for _ in 0..<(Self.bytesToWrite / Self.chunkSize) {
            try handle.write(contentsOf: chunk)
        }
        try handle.synchronize()
        try handle.close()

        let after = try await reader.read()
        let drop = before - after
        #expect(
            drop >= Int64(Self.bytesToWrite / 2),
            "free space before \(before), after \(after): dropped \(drop) bytes after writing \(Self.bytesToWrite)"
        )
    }
}
