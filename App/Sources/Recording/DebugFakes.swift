#if DEBUG
import DriveLoggerCore
import Foundation

/// DEBUG builds only: synthetic values for simulator screenshots (the
/// simulator has no road packs). Names are made up. No effect in Release.
enum DebugFakes {
    static var mapsStatus: RoadPackLibrary.Status {
        RoadPackLibrary.Status(
            packs: [
                .preview("national", bytes: 120_000_000, hash: "0f0e0d0c", coverage: false),
                .preview("region-a", hash: "a1b2c3d4"),
                .preview("region-b", hash: "5e6f7a8b", pending: true),
            ],
            scansCompleted: 1, storeBytes: 216_000_000)
    }

    /// `-uiFakeDownloads 1` / `-uiFakeOffline 1`: a synthetic manifest with a
    /// row in each state (installed, update available, downloading 42 %,
    /// failed, waiting for Wi-Fi, one pack not in the manifest).
    @MainActor
    static func downloadsModel(offline: Bool, connection: PackDownloadRules.Connection = .unmetered,
                               cellularAllowed: Bool = false) -> MapsModel {
        let connection = offline ? .none : connection
        return MapsModel(
            status: MapsPreviewData.status, manifest: MapsPreviewData.manifest,
            downloads: MapsPreviewData.downloads(connection: connection, cellularAllowed: cellularAllowed),
            refresh: connection == .none ? .failed(offline: true) : .ok)
    }

    /// `-uiFakeRemovalPending 1`: one pack marked for removal and a run
    /// active (B5): the row offers Download again, and Remove warns that
    /// navigation loses the map until the app restarts.
    @MainActor
    static var removalModel: MapsModel {
        MapsModel(
            status: RoadPackLibrary.Status(
                packs: [
                    .preview("national", bytes: 41_000_000, hash: "0f0e0d0c", coverage: false),
                    .preview("region-a", hash: "a1b2c3d4", pending: true),
                    .preview("region-b", hash: "5e6f7a8b"),
                ],
                scansCompleted: 1, storeBytes: 134_000_000),
            manifest: MapsPreviewData.manifest, downloads: PackDownloader.Snapshot(), refresh: .ok, runActive: true)
    }

    /// `-uiFakeConnection none|cellular|metered|wifi`.
    static func connection(_ name: String?) -> PackDownloadRules.Connection? {
        switch name {
        case "none": PackDownloadRules.Connection.none
        case "cellular": .cellular
        case "metered": .meteredWiFi
        case "wifi": .unmetered
        default: nil
        }
    }

    /// `-uiFakeMapsShort 1`: a short list (two uninstalled packs, no downloads),
    /// so the Never section fits on one screenshot.
    @MainActor
    static var shortMapsModel: MapsModel {
        let manifest = PackManifest.preview([
            ("region-a", .region, "Region A", "a1b2c3d400000000"),
            ("region-c", .region, "Region C", "1122334400000000"),
        ])
        return MapsModel(status: RoadPackLibrary.Status(packs: [], scansCompleted: 1, storeBytes: 0),
                         manifest: manifest, downloads: PackDownloader.Snapshot(), refresh: .ok)
    }

    /// `-uiFakeFirstLaunchList ok|offline|cached`: the first-launch maps list
    /// from a synthetic manifest (`zz-NN`, "Region A", boxes near (0, 0)), so a
    /// screenshot never shows the real list. `ok`: the fetch succeeds;
    /// `offline`: no cache and the fetch fails (no list); `cached`: a cache and
    /// the fetch fails (offline with a cached list).
    static func firstLaunchManifest(mode: String, downloader: PackDownloader) -> PackManifestService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uiFakeManifest-\(mode)")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(syntheticManifestJSON.utf8)
        if mode == "cached" {
            struct Envelope: Encodable { var fetchedAt: Double; var manifest: Data }
            let envelope = Envelope(fetchedAt: Date().timeIntervalSince1970, manifest: data)
            try? JSONEncoder().encode(envelope).write(
                to: directory.appendingPathComponent(PackManifestService.cacheFileName))
        }
        let succeeds = mode == "ok"
        return PackManifestService(
            cacheDirectory: directory, storeDirectory: nil, downloader: downloader,
            fetch: { _ in
                if succeeds { return data }
                throw URLError(.notConnectedToInternet)
            })
    }

    /// National plus eight boxes on a grid near (0, 0): zz-01 at the origin,
    /// zz-02 and zz-03 touching it, the rest far away.
    static var syntheticManifestJSON: String {
        let boxes: [(String, String, [Double], Int)] = [
            ("zz-01", "Region A", [0, 0, 0.5, 0.5], 35_000_000), ("zz-02", "Region B", [0.5, 0, 1, 0.5], 28_000_000),
            ("zz-03", "Region C", [0, 0.5, 0.5, 1], 47_000_000), ("zz-04", "Region D", [3, 3, 4, 4], 22_000_000),
            ("zz-05", "Region E", [5, 3, 6, 4], 31_000_000), ("zz-06", "Region F", [3, 5, 4, 6], 26_000_000),
            ("zz-07", "Region G", [5, 5, 6, 6], 19_000_000), ("zz-08", "Region H", [7, 3, 8, 4], 40_000_000),
        ]
        func entry(_ name: String, _ kind: String, _ title: String, _ box: [Double], _ size: Int, _ index: Int) -> String {
            let hash = String(format: "%016x", 0xA000_0000 + index)
            return """
            {"name":"\(name)","kind":"\(kind)","title":{"uk":"\(title)","en":"\(title)"},"bbox":\(box),\
            "url":"/packs/v1/\(name)-\(hash).roadpack","size":\(size),"sha256":"\(String(repeating: "0", count: 64))",\
            "contentHash":"\(hash)","formatVersion":1,"osmTimestamp":1760000000}
            """
        }
        var entries = [entry("zz-00", "national", "National roads", [-10, -10, 10, 10], 41_000_000, 0)]
        for (index, box) in boxes.enumerated() { entries.append(entry(box.0, "region", box.1, box.2, box.3, index + 1)) }
        return """
        {"schema":2,"generated":"2026-01-01T00:00:00Z","license":"ODbL 1.0",\
        "licenseUrl":"https://opendatacommons.org/licenses/odbl/1-0/","attribution":"OpenStreetMap contributors",\
        "packs":[\(entries.joined(separator: ","))]}
        """
    }
}
#endif
