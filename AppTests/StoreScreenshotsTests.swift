import Foundation
import Testing

@testable import DriveLogger

@Suite("Store screenshot mode")
struct StoreScreenshotsTests {
    private func defaults(_ values: [String: Any] = [:]) -> UserDefaults {
        let suite = UserDefaults(suiteName: "StoreScreenshotsTests-\(UUID().uuidString)")!
        for (key, value) in values { suite.set(value, forKey: key) }
        return suite
    }

    @Test("-storeScreenshots turns the mode on; without it the mode is off")
    func parsing() {
        #expect(StoreScreenshotMode.from(defaults: defaults()).isOn == false)
        #expect(StoreScreenshotMode.from(defaults: defaults([StoreScreenshotMode.key: true])).isOn)
        #expect(StoreScreenshotMode.from(defaults: defaults([StoreScreenshotMode.key: false])).isOn == false)
    }

    @Test("on: DEMO badge, Stop demo and the developer strip are hidden, whatever the setting")
    func hidesExactlyThree() {
        let on = StoreScreenshotMode(isOn: true)
        #expect(on.showsDemoControls == false)
        #expect(on.showsDebugStrip(setting: true) == false)
        #expect(on.showsDebugStrip(setting: false) == false)
    }

    @Test("off: the demo controls show and the strip follows the driver's setting")
    func offChangesNothing() {
        let off = StoreScreenshotMode.off
        #expect(off.showsDemoControls)
        #expect(off.showsDebugStrip(setting: true))
        #expect(off.showsDebugStrip(setting: false) == false)
    }

    @Test("-storeDemoReadyAt: absent is nil, a value is read")
    func readyAt() {
        #expect(StoreScreenshotMode.readyAt(defaults: defaults()) == nil)
        #expect(StoreScreenshotMode.readyAt(defaults: defaults([StoreScreenshotMode.readyKey: 42.5])) == 42.5)
    }

    @MainActor
    @Test("the ready file appears once the demo clock reaches the second, not before")
    func signalsReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(StoreScreenshotMode.readyFileName)
        var clock = 0.0
        let task = Task { @MainActor in
            await StoreScreenshotMode.signalReady(at: 5, elapsed: { clock }, directory: directory)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        clock = 4.99
        try await Task.sleep(for: .milliseconds(50))
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        clock = 5
        await task.value
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
