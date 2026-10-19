import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// Records the configurations the downloader asked for, and keeps them so a
/// test can read the flags the downloader set on them afterwards.
private final class ConfigRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var configs: [URLSessionConfiguration] = []
    var all: [URLSessionConfiguration] { lock.withLock { configs } }

    @Sendable func make() -> URLSessionConfiguration {
        let configuration = PackStub.configuration()
        lock.withLock { configs.append(configuration) }
        return configuration
    }
}

private final class AskCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func bump() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

private func rangeStart(_ request: URLRequest) -> Int? {
    request.value(forHTTPHeaderField: "Range").flatMap {
        $0.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").first.flatMap { Int($0) }
    }
}

@Suite("Map download network policy (UX-17)")
struct PackNetworkPolicyTests {
    // MARK: Metered Wi-Fi and the toggle

    @Test("Metered Wi-Fi with the switch off waits in its own state and makes no request; switch on starts it")
    func meteredWiFi() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let downloader = env.downloader(connection: .meteredWiFi, cellular: false)
        await downloader.start(env.pack(stub))
        #expect(await downloader.snapshot().states["region-a"] == .waitingMeteredWiFi)
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.isEmpty)
        await downloader.setCellularAllowed(true)
        await downloader.waitUntilIdle()
        #expect(env.installedFiles.count == 1)
    }

    @Test("The snapshot carries the raw path, the downloader's switch and the policy")
    func snapshotCarriesInputs() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let downloader = env.downloader(connection: .none, cellular: false)
        var snapshot = await downloader.snapshot()
        #expect(snapshot.path == nil && !snapshot.cellularAllowed && snapshot.policy == .offline)
        let wifi = PackPath(satisfied: true, usesWiFi: true, constrained: true)
        await downloader.setPath(wifi)
        await downloader.setCellularAllowed(true)
        snapshot = await downloader.snapshot()
        #expect(snapshot.path == wifi && snapshot.connection == .meteredWiFi)
        #expect(snapshot.cellularAllowed && snapshot.policy == .allowed)
        await downloader.setRecordActive(true)
        snapshot = await downloader.snapshot()
        #expect(snapshot.recordActive && snapshot.policy == .pausedForRecording)
    }

    // MARK: A transfer's session keeps the flags it was made with

    @Test("Turning the switch on restarts a transfer made with it off, under a session that allows cellular")
    func switchOnRestartsRunningTransfer() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { request, attempt in
            if attempt == 0 { var reply = env.full(); reply.hold = true; return reply }
            return rangeStart(request).map { env.partial(from: $0) } ?? env.full()
        }
        let recorder = ConfigRecorder()
        let downloader = PackDownloader(directory: env.dirs.store, library: env.library, connection: .unmetered,
                                        cellularAllowed: false, makeConfiguration: recorder.make)
        await downloader.start(env.pack(stub))
        #expect(await eventually { stub.requests.count == 1 && stub.bytesServed > 0 })
        #expect(recorder.all.count == 1 && recorder.all[0].allowsCellularAccess == false)

        await downloader.setCellularAllowed(true)
        #expect(await eventually { recorder.all.count == 2 && env.installedFiles.count == 1 })
        #expect(recorder.all.last?.allowsCellularAccess == true)
        #expect(recorder.all.last?.allowsExpensiveNetworkAccess == true)
        #expect(recorder.all.last?.allowsConstrainedNetworkAccess == true)
        #expect(stub.requests.count == 2 && rangeStart(stub.requests[1]) != nil, "continues from the partial")
        await downloader.cancel(name: "region-a")
        await downloader.waitUntilIdle()
    }

    @Test("Turning the switch off leaves a transfer on an unmetered path running")
    func switchOffKeepsRunning() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in var reply = env.full(); reply.hold = true; return reply }
        let recorder = ConfigRecorder()
        let downloader = PackDownloader(directory: env.dirs.store, library: env.library, connection: .unmetered,
                                        cellularAllowed: true, makeConfiguration: recorder.make)
        await downloader.start(env.pack(stub))
        #expect(await eventually { stub.bytesServed > 0 })
        await downloader.setCellularAllowed(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.all.count == 1 && stub.requests.count == 1)
        if case .downloading? = await downloader.snapshot().states["region-a"] {} else {
            Issue.record("should still be downloading")
        }
        await downloader.cancel(name: "region-a")
        await downloader.waitUntilIdle()
    }

    @Test("The system refusing a metered path before the monitor reports it waits instead of failing or looping")
    func refusedWaits() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let refusal = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.constrained.rawValue])
        let stub = PackStub { _, attempt in
            if attempt == 0 { return .init(failure: refusal) }
            return env.full()
        }
        // The monitor still says unmetered (stale), the switch is off.
        let downloader = env.downloader(connection: .unmetered, cellular: false)
        await downloader.start(env.pack(stub))
        #expect(await eventually { await downloader.snapshot().states["region-a"] == .waitingMeteredWiFi })
        try await Task.sleep(for: .milliseconds(200))
        #expect(stub.requests.count == 1, "no retry loop")
        #expect(await downloader.snapshot().states["region-a"] == .waitingMeteredWiFi, "not Failed")

        // The monitor catches up; then the user allows cellular data.
        await downloader.setPath(PackPath(satisfied: true, usesWiFi: true, constrained: true))
        #expect(await downloader.snapshot().states["region-a"] == .waitingMeteredWiFi)
        await downloader.setCellularAllowed(true)
        await downloader.waitUntilIdle()
        #expect(env.installedFiles.count == 1 && stub.requests.count == 2)
    }

    // MARK: One path from the switch to the downloader

    private func suite() throws -> (UserDefaults, String) {
        let name = "zz-cellular-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("Writing the UserDefault reaches the downloader without any screen: a waiting pack starts")
    func defaultReachesDownloader() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let stub = PackStub { _, _ in env.full() }
        let downloader = env.downloader(connection: .cellular, cellular: false)
        let observer = CellularSettingObserver(defaults: defaults, downloader: downloader)
        await downloader.start(env.pack(stub))
        #expect(await downloader.snapshot().states["region-a"] == .waitingForWiFi)
        defaults.set(true, forKey: MapsSettings.cellularKey)
        #expect(await eventually { env.installedFiles.count == 1 })
        #expect(await downloader.snapshot().cellularAllowed)
        withExtendedLifetime(observer) {}
    }

    @Test("A quick on/off burst ends on the last value written")
    func burstEndsOnLast() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let downloader = env.downloader(connection: .cellular, cellular: false)
        let observer = CellularSettingObserver(defaults: defaults, downloader: downloader)
        for round in 0..<40 { defaults.set(round % 2 == 0, forKey: MapsSettings.cellularKey) }
        defaults.set(true, forKey: MapsSettings.cellularKey)
        #expect(await eventually { await downloader.snapshot().cellularAllowed })
        for round in 0..<40 { defaults.set(round % 2 == 1, forKey: MapsSettings.cellularKey) }
        defaults.set(false, forKey: MapsSettings.cellularKey)
        #expect(await eventually { await downloader.snapshot().cellularAllowed == false })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await downloader.snapshot().cellularAllowed == false, "no older value lands after the latest")
        withExtendedLifetime(observer) {}
    }

    @Test("A switch already on at launch is delivered to a downloader that started with it off")
    func initialValue() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: MapsSettings.cellularKey)
        let downloader = env.downloader(connection: .cellular, cellular: false)
        let observer = CellularSettingObserver(defaults: defaults, downloader: downloader)
        #expect(await eventually { await downloader.snapshot().cellularAllowed })
        withExtendedLifetime(observer) {}
    }

    // MARK: The state line and the rows come from one snapshot (UX-16)

    @Test("Network line text per connection and switch")
    func lineText() {
        func line(_ c: PackDownloadRules.Connection, _ on: Bool) -> String {
            MapsText.networkLine(connection: c, cellularAllowed: on).text
        }
        #expect(line(.unmetered, false) == "On Wi-Fi" && line(.unmetered, true) == "On Wi-Fi")
        #expect(line(.cellular, false) == "On cellular — maps wait for Wi-Fi")
        #expect(line(.cellular, true) == "On cellular")
        #expect(line(.meteredWiFi, false) == "On metered Wi-Fi — maps wait for unmetered Wi-Fi")
        #expect(line(.meteredWiFi, true) == "On metered Wi-Fi")
        #expect(line(.none, false) == "Offline" && line(.none, true) == "Offline")
        #expect(MapsText.stateText(.waitingMeteredWiFi) == "Waiting — this Wi-Fi is metered")
    }

    @Test("For every connection and switch, a queued row waits exactly when the line says maps wait")
    func lineAgreesWithRows() async throws {
        let connections: [PackDownloadRules.Connection] = [.none, .unmetered, .cellular, .meteredWiFi]
        for connection in connections {
            for cellular in [false, true] {
                let env = try DownloadEnv()
                defer { env.dirs.remove() }
                let stub = PackStub { _, _ in var reply = env.full(); reply.hold = true; return reply }
                let downloader = env.downloader(connection: connection, cellular: cellular)
                await downloader.start(env.pack(stub))
                let snapshot = await downloader.snapshot()
                let state = try #require(snapshot.states["region-a"])
                let status = MapsText.status(pack: nil, installed: nil, download: state, updatedNextStart: false)
                let line = MapsText.networkLine(snapshot)
                let label = "\(connection) cellular=\(cellular)"
                let rowWaits: Bool = switch status {
                case .waitingForWiFi, .waitingMeteredWiFi, .offline: true
                default: false
                }
                #expect(rowWaits == (line.tone == .caution), "\(label): \(status) vs \(line.text)")
                switch (connection, cellular) {
                case (.cellular, false): #expect(status == .waitingForWiFi, "\(label)")
                case (.meteredWiFi, false): #expect(status == .waitingMeteredWiFi, "\(label)")
                case (.none, _): #expect(status == .offline, "\(label)")
                default: if case .downloading = status {} else { Issue.record("\(label): expected downloading, got \(status)") }
                }
                await downloader.cancel(name: "region-a")
                await downloader.waitUntilIdle()
            }
        }
    }

    // MARK: Diagnostics

    @Test("Diagnostics rows: path flags, both switch values with a mismatch flagged, policy, queued jobs")
    func diagnostics() {
        var snapshot = PackDownloader.Snapshot(
            states: ["region-b": .waitingMeteredWiFi, "region-a": .queued, "region-c": .failed("404")],
            connection: .meteredWiFi, cellularAllowed: false,
            path: PackPath(satisfied: true, usesWiFi: true, expensive: true))
        var rows = NetworkDiagnosticsText.rows(snapshot, setting: false)
        #expect(rows.map(\.label) == ["Path", "Maps connection", "Cellular switch", "Policy", "region-a", "region-b", "region-c"])
        #expect(rows[0].value == "satisfied · Wi-Fi · expensive yes · constrained no")
        #expect(rows[1].value == "metered Wi-Fi")
        #expect(rows[2].value == "setting off · downloader off" && !rows[2].isProblem)
        #expect(rows[3].value == "waiting (metered Wi-Fi, switch off)")
        #expect(rows[5].value == "waiting, metered Wi-Fi")
        rows = NetworkDiagnosticsText.rows(snapshot, setting: true)
        #expect(rows[2].value == "setting on · downloader off · MISMATCH" && rows[2].isProblem)
        snapshot.path = nil
        #expect(NetworkDiagnosticsText.path(snapshot) == "not reported (connection metered Wi-Fi)")
        snapshot.path = PackPath(satisfied: true, usesWiFi: true, usesCellular: true)
        #expect(NetworkDiagnosticsText.path(snapshot) == "satisfied · Wi-Fi + cellular · expensive no · constrained no")
    }

    // MARK: A 404 takes the fresh manifest entry once (R67.1-7)

    private func freshEnv(freshStatus: Int = 200) throws -> (DownloadEnv, PackStub, PackStub, PackManifest.Pack, PackManifest.Pack) {
        let env = try DownloadEnv()
        let oldStub = PackStub { _, _ in .init(status: 404) }
        let newStub = PackStub { _, _ in freshStatus == 200 ? env.full() : .init(status: freshStatus) }
        var old = env.pack(oldStub)
        old.contentHash = "1111111111111111"
        return (env, oldStub, newStub, old, env.pack(newStub))
    }

    @Test("404 to a pack: one forced refresh, one retry with the fresh entry of the same name; it installs")
    func notFoundRetriesWithFresh() async throws {
        let (env, oldStub, newStub, old, fresh) = try freshEnv()
        defer { env.dirs.remove() }
        let asked = AskCounter()
        let downloader = env.downloader()
        await downloader.setFreshEntry { name in
            asked.bump()
            return name == "region-a" ? fresh : nil
        }
        await downloader.start(old)
        await downloader.waitUntilIdle()
        #expect(asked.count == 1)
        #expect(oldStub.requests.count == 1 && newStub.requests.count == 1)
        #expect(env.installedFiles == [try StoreFixture.storedName("region-a", env.data)])
        #expect(await downloader.snapshot().states.isEmpty)
        #expect(env.downloadFiles.isEmpty)
    }

    @Test("A second 404 fails: no second refresh, no third request")
    func notFoundTwiceFails() async throws {
        let (env, oldStub, newStub, old, fresh) = try freshEnv(freshStatus: 404)
        defer { env.dirs.remove() }
        let asked = AskCounter()
        let downloader = env.downloader()
        await downloader.setFreshEntry { _ in asked.bump(); return fresh }
        await downloader.start(old)
        await downloader.waitUntilIdle()
        #expect(asked.count == 1 && oldStub.requests.count == 1 && newStub.requests.count == 1)
        #expect(await downloader.snapshot().states["region-a"] == .failed("404: the pack is not on the server"))
        #expect(env.installedFiles.isEmpty)
    }

    @Test("404 and the name is gone from the fresh manifest: fails as before, after one refresh")
    func notFoundNameGone() async throws {
        let (env, oldStub, newStub, old, _) = try freshEnv()
        defer { env.dirs.remove() }
        let asked = AskCounter()
        let downloader = env.downloader()
        await downloader.setFreshEntry { _ in asked.bump(); return nil }
        await downloader.start(old)
        await downloader.waitUntilIdle()
        #expect(asked.count == 1 && oldStub.requests.count == 1 && newStub.requests.isEmpty)
        #expect(await downloader.snapshot().states["region-a"] == .failed("404: the pack is not on the server"))
    }

    @Test("404 and the refresh returns the same entry: fails without another request")
    func notFoundSameEntry() async throws {
        let (env, oldStub, _, old, _) = try freshEnv()
        defer { env.dirs.remove() }
        let downloader = env.downloader()
        await downloader.setFreshEntry { _ in old }
        await downloader.start(old)
        await downloader.waitUntilIdle()
        #expect(oldStub.requests.count == 1)
        #expect(await downloader.snapshot().states["region-a"] == .failed("404: the pack is not on the server"))
    }

    @Test("Without a refresh hook a 404 fails as before")
    func notFoundNoHook() async throws {
        let (env, oldStub, _, old, _) = try freshEnv()
        defer { env.dirs.remove() }
        let downloader = env.downloader()
        await downloader.start(old)
        await downloader.waitUntilIdle()
        #expect(oldStub.requests.count == 1)
        #expect(await downloader.snapshot().states["region-a"] == .failed("404: the pack is not on the server"))
    }
}
