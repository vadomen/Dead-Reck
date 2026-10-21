import Foundation
import Testing

@testable import DriveLoggerCore

/// R11.2-4 / R12.1-1 / R18.1-2: `metrics.json` rows and configs written by
/// earlier builds decode (a key added later takes its default), encoding is
/// unchanged, and an undecodable file is only replaced once a copy exists.
@Suite("Navigation metrics coding")
struct NavigationMetricsCodingTests {
    typealias S = SyntheticDrive

    /// Labels of a value's stored properties, from `Mirror`.
    static func storedProperties(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    static func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func metrics() -> ReplayMetrics {
        let (events, truth) = NavigationPinScoringTests.scenario(pinTimes: [40, 41.5])
        var metrics = ReplayMetrics(NavigationPinScoringTests.run(events, truth: truth, window: 3))
        // The road keys (N3.2b) filled, so the round trip covers them.
        metrics.roads = [ReplayRoadPack(contentHash: "0123456789abcdef", formatVersion: 1, osmTimestamp: 1,
                                        gridID: "fedcba9876543210")]
        metrics.roadSetHash = "00112233445566ff"
        var road = ReplayRoadMetrics(wrongRoadToleranceM: 20)
        road.truth = ["matched": 2, "noCourse": 1]
        road.verdicts = ["right": ReplayRoadMetrics.Count()]
        road.wrongShare = 0
        road.residualsAll = DistanceStats([1, 2, 3])
        road.rejectedFixes = [[12.5, 8]]
        road.fixes = [ReplayRoadFix(t: 1, distanceM: 2, accuracyM: 5, truth: .matched)]
        metrics.roadMetrics = road
        // The scoreUntilT keys filled too.
        metrics.scoreUntilT = 60
        // The N3.3 attach keys filled too.
        metrics.roadsAttachedAfterInputs = 1234
        metrics.attachedRoadSetHash = "00112233445566ff"
        metrics.roadsExtendedAfterInputs = [2345, 3456]
        metrics.checkpointsAfterScoreUntil = 2
        // The excludeFixes key filled too.
        metrics.fixesExcludedByTruth = .init(ranges: [.init(fromT: -1, toT: 251, reason: "r")], fixes: 3,
                                             cleanFixes: 2, cleanFixCheckpoints: 1)
        // The N3-FIXPIN decisions filled too (relative metres only).
        metrics.fixPinDecisions = [FixPinDecision(
            t: 41.5, refinement: false, offsetEastM: 240, offsetNorthM: 160, chi2: 82, significant: true,
            sources: [.init(source: "accessory", fixesInWindow: 30, wasDownweighted: false,
                            road: .init(fixes: 30, pathM: 298, asGivenM: 40.5, shiftedM: 1.9, verdict: .pin),
                            twoPin: .init(previousT: 1, chi2: 0.5, pathM: 500, turnDeg: 90, verdict: nil),
                            downweighted: true, sourceChi2: nil, restored: false)])]
        return metrics
    }

    // MARK: NavigationConfig

    @Test("NavigationConfig.CodingKeys lists every stored property, so none is dropped from encoding")
    func configKeysComplete() throws {
        let keys = Set(NavigationConfig.CodingKeys.allCases.map(\.stringValue))
        #expect(keys == Self.storedProperties(NavigationConfig()))
        #expect(Set(try Self.object(Self.sortedJSON(NavigationConfig())).keys) == keys)
    }

    @Test("A config missing any one key decodes with that key's default, every other value kept")
    func configMissingEachKey() throws {
        // A config with every value moved off its default, so a key that
        // fell back to the default by mistake would show.
        var custom = NavigationConfig()
        var object = try Self.object(Self.sortedJSON(custom))
        for (key, value) in object {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                object[key] = number.doubleValue == 0 ? 1 : number.doubleValue * 2
            }
        }
        custom = try JSONDecoder().decode(NavigationConfig.self, from: JSONSerialization.data(withJSONObject: object))
        let customObject = try Self.object(Self.sortedJSON(custom))
        let defaults = try Self.object(Self.sortedJSON(NavigationConfig()))
        for key in NavigationConfig.CodingKeys.allCases.map(\.stringValue) {
            #expect((customObject[key] as? NSNumber) != (defaults[key] as? NSNumber), "\(key) was not moved off its default")
            var old = customObject
            old.removeValue(forKey: key)
            let decoded = try JSONDecoder().decode(NavigationConfig.self, from: JSONSerialization.data(withJSONObject: old))
            let back = try Self.object(Self.sortedJSON(decoded))
            for other in defaults.keys {
                let expected = other == key ? defaults[other] : customObject[other]
                #expect((back[other] as? NSNumber) == (expected as? NSNumber), "missing \(key): \(other)")
            }
        }
    }

    @Test("Config keys added in N2.x/N4 (the ones older metrics.json rows lack) decode from an old row's config")
    func configFromOlderBuild() throws {
        var object = try Self.object(Self.sortedJSON(NavigationConfig()))
        for key in ["lateManualFixWindowS", "maxCatchUpSteps", "heldFixTimeoutS", "maxForwardJumpS",
                    "staleSpeedDecayS", "extrapolationHorizonS"] {
            #expect(object.removeValue(forKey: key) != nil, "\(key)")
        }
        object["seed"] = 3
        object["someFutureKey"] = 1.5
        let decoded = try JSONDecoder().decode(NavigationConfig.self, from: JSONSerialization.data(withJSONObject: object))
        var expected = NavigationConfig()
        expected.seed = 3
        #expect(decoded == expected)
        // An empty object is the default config; a wrong type still fails.
        #expect(try JSONDecoder().decode(NavigationConfig.self, from: Data("{}".utf8)) == NavigationConfig())
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NavigationConfig.self, from: Data(#"{"seed":"one"}"#.utf8))
        }
    }

    @Test("Config encoding is unchanged: canonical JSON round-trips byte for byte, and the hash with it")
    func configRoundTripBytes() throws {
        var config = NavigationConfig(seed: UInt64.max - 7)
        config.extrapolationHorizonS = 2.5
        config.particleCount = 123
        let bytes = config.canonicalJSON()
        let decoded = try JSONDecoder().decode(NavigationConfig.self, from: bytes)
        #expect(decoded == config)
        #expect(decoded.canonicalJSON() == bytes)
        #expect(decoded.hashHex == config.hashHex)
        // The live app's default config hash, as N4's sidecars record it.
        #expect(NavigationConfig().hashHex == NavigationConfig(seed: 1).hashHex)
    }

    // MARK: NavigationCounters

    @Test("NavigationCounters: every stored property has a key; a missing counter is 0")
    func countersMissingEachKey() throws {
        var full = NavigationCounters()
        var object = try Self.object(Self.sortedJSON(full))
        #expect(Set(object.keys) == Self.storedProperties(full))
        for (index, key) in object.keys.sorted().enumerated() { object[key] = index + 1 }
        full = try JSONDecoder().decode(NavigationCounters.self, from: JSONSerialization.data(withJSONObject: object))
        for key in object.keys {
            var old = object
            old.removeValue(forKey: key)
            let decoded = try JSONDecoder().decode(NavigationCounters.self, from: JSONSerialization.data(withJSONObject: old))
            let back = try Self.object(Self.sortedJSON(decoded))
            #expect(back[key] as? Int == 0, "\(key)")
            for other in object.keys where other != key {
                #expect(back[other] as? Int == object[other] as? Int, "missing \(key): \(other)")
            }
        }
        #expect(try Self.sortedJSON(JSONDecoder().decode(NavigationCounters.self, from: Self.sortedJSON(full)))
            == Self.sortedJSON(full))
    }

    // MARK: ReplayMetrics

    @Test("ReplayMetrics.CodingKeys lists every stored property")
    func metricsKeysComplete() throws {
        let metrics = Self.metrics()
        #expect(Set(ReplayMetrics.CodingKeys.allCases.map(\.stringValue)) == Self.storedProperties(metrics))
        #expect(ReplayMetrics.originalKeys.isSubset(of: Set(ReplayMetrics.CodingKeys.allCases)))
    }

    @Test("metrics.json round-trips byte for byte through the tolerant decoder")
    func metricsRoundTripBytes() throws {
        let metrics = Self.metrics()
        let data = try ReplayReport.metricsJSON([metrics])
        let decoded = try JSONDecoder().decode([ReplayMetrics].self, from: data)
        #expect(decoded == [metrics])
        #expect(try ReplayReport.metricsJSON(decoded) == data)
    }

    @Test("A row missing any key added after N2 decodes (nil or default); a row missing an original key does not")
    func metricsMissingEachLaterKey() throws {
        let data = try ReplayReport.metricsJSON([Self.metrics()])
        let row = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])[0]
        let later = Set(ReplayMetrics.CodingKeys.allCases).subtracting(ReplayMetrics.originalKeys)
        #expect(later.map(\.stringValue).sorted()
            == ["consistency", "consistencyWithTruthSigma", "motionStartT", "pinScoring", "pins",
                "checkpointsAfterScoreUntil", "roadMetrics", "roadSetHash", "roads", "scoreUntilT",
                "roadsAttachedAfterInputs", "attachedRoadSetHash", "roadsExtendedAfterInputs", "fixesExcludedByTruth", "fixPinDecisions",
                "maxErrorByKind"].sorted())
        for key in later {
            var old = row
            old.removeValue(forKey: key.stringValue)
            let file = try JSONSerialization.data(withJSONObject: [old])
            #expect(ReplayReport.existingMetricsDecodeError(file) == nil, "\(key)")
            let decoded = try JSONDecoder().decode([ReplayMetrics].self, from: file)[0]
            switch key {
            case .consistency: #expect(decoded.consistency == nil)
            case .consistencyWithTruthSigma: #expect(decoded.consistencyWithTruthSigma == nil)
            case .motionStartT: #expect(decoded.motionStartT == nil)
            case .pinScoring: #expect(decoded.pinScoring == nil)
            case .pins: #expect(decoded.pins == nil)
            case .roads: #expect(decoded.roads == nil)
            case .roadSetHash: #expect(decoded.roadSetHash == nil)
            case .roadMetrics: #expect(decoded.roadMetrics == nil)
            case .scoreUntilT: #expect(decoded.scoreUntilT == nil)
            case .checkpointsAfterScoreUntil: #expect(decoded.checkpointsAfterScoreUntil == nil)
            case .roadsAttachedAfterInputs: #expect(decoded.roadsAttachedAfterInputs == nil)
            case .attachedRoadSetHash: #expect(decoded.attachedRoadSetHash == nil)
            case .roadsExtendedAfterInputs: #expect(decoded.roadsExtendedAfterInputs == nil)
            case .fixesExcludedByTruth: #expect(decoded.fixesExcludedByTruth == nil)
            case .fixPinDecisions: #expect(decoded.fixPinDecisions == nil)
            case .maxErrorByKind: #expect(decoded.maxErrorByKind == nil)
            default: Issue.record("unexpected later key \(key)")
            }
        }
        for key in ReplayMetrics.originalKeys {
            var old = row
            old.removeValue(forKey: key.stringValue)
            let file = try JSONSerialization.data(withJSONObject: [old])
            // Optional originals (nil values) are written as absent keys, so
            // only the non-optional ones can be required.
            if ["maxErrorM", "maxErrorPercent", "endErrorM", "endErrorPercent", "convergedT", "convergedDistanceM",
                "finalHeadingStdDeg"].contains(key.stringValue) {
                #expect(ReplayReport.existingMetricsDecodeError(file) == nil, "\(key)")
            } else {
                #expect(ReplayReport.existingMetricsDecodeError(file) != nil, "\(key)")
            }
        }
    }

    @Test("An older row (config and counters without later keys, no consistency/pins/pinScoring) merges with a new run")
    func olderRowMerges() throws {
        let metrics = Self.metrics()
        let data = try ReplayReport.metricsJSON([metrics])
        var row = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])[0]
        for key in ["consistency", "consistencyWithTruthSigma", "pins", "pinScoring", "motionStartT"] {
            row.removeValue(forKey: key)
        }
        var config = try #require(row["config"] as? [String: Any])
        for key in ["lateManualFixWindowS", "maxCatchUpSteps", "heldFixTimeoutS", "maxForwardJumpS", "staleSpeedDecayS"] {
            config.removeValue(forKey: key)
        }
        row["config"] = config
        var counters = try #require(row["counters"] as? [String: Any])
        for key in ["fixesHeld", "heldFixesUsed", "macroSteps", "lateManualFixes"] { counters.removeValue(forKey: key) }
        row["counters"] = counters
        var checkpoints = try #require(row["checkpoints"] as? [[String: Any]])
        for i in checkpoints.indices { checkpoints[i].removeValue(forKey: "inside95WithTruthSigma") }
        row["checkpoints"] = checkpoints
        row["mode"] = "older-mode"
        let old = try JSONSerialization.data(withJSONObject: [row])
        #expect(ReplayReport.existingMetricsDecodeError(old) == nil)
        let merged = try ReplayReport.mergedMetrics(existing: old, adding: [metrics])
        #expect(merged.map(\.mode).sorted() == ["older-mode", metrics.mode].sorted())
        let older = try #require(merged.first { $0.mode == "older-mode" })
        #expect(older.config.lateManualFixWindowS == NavigationConfig().lateManualFixWindowS)
        #expect(older.counters.fixesHeld == 0 && older.counters.steps == metrics.counters.steps)
        #expect(older.checkpoints.allSatisfy { $0.inside95WithTruthSigma == nil })
        #expect(older.checkpoints == metrics.checkpoints.map { cp in
            var cp = cp
            cp.inside95WithTruthSigma = nil
            return cp
        })
    }

    // MARK: Undecodable backup (R18.1-2)

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-coding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The undecodable copy is written to a new name and never overwrites an older copy")
    func backupNeverOverwrites() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try ReplayReport.keepUndecodableMetrics(Data("one".utf8), in: dir, stamp: "S")
        let second = try ReplayReport.keepUndecodableMetrics(Data("two".utf8), in: dir, stamp: "S")
        let third = try ReplayReport.keepUndecodableMetrics(Data("three".utf8), in: dir, stamp: "S")
        #expect(first.lastPathComponent == "metrics.undecodable-S.json")
        #expect(second.lastPathComponent == "metrics.undecodable-S-1.json")
        #expect(third.lastPathComponent == "metrics.undecodable-S-2.json")
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
        #expect(try Data(contentsOf: third) == Data("three".utf8))
    }

    @Test("When the copy cannot be written, keepUndecodableMetrics throws (replay_nav then leaves metrics.json alone)")
    func backupFailureThrows() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("no-such-directory")
        #expect(throws: (any Error).self) {
            try ReplayReport.keepUndecodableMetrics(Data("x".utf8), in: missing, stamp: "S")
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
