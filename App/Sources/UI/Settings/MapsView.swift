import DriveLoggerCore
import Foundation
import Observation
import SwiftUI

/// UserDefaults keys of Settings → Maps.
enum MapsSettings {
    /// "Use cellular data" for map downloads; off by default.
    static let cellularKey = "maps.cellularAllowed"
}

/// One row of Settings → Maps: a manifest pack merged with the installed one
/// of the same name, or an installed pack the manifest does not list.
struct MapsRow: Identifiable, Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case download, cancel, update
        /// A pack marked for removal: clears the mark (B5, prompt 38).
        case downloadAgain
    }

    enum Status: Hashable, Sendable {
        case notInstalled
        case queued
        case waitingForWiFi
        /// Toggle off on a Personal Hotspot or Low Data Mode Wi-Fi (UX-17).
        case waitingMeteredWiFi
        case offline
        case downloading(percent: Int)
        case pausedForRecording
        case verifying
        case installed
        case updateAvailable
        /// Updated while a run was active.
        case updatedNextStart
        case failed(String)
        case removalPending
    }

    /// The pack's name (`ua-05` style): the id, and the title of a pack the
    /// manifest does not list.
    var id: String
    var title: String
    var sizeBytes: Int64?
    var osmTimestamp: Int64?
    var status: Status
    var action: Action?
    /// The manifest entry: what Download and Update fetch.
    var pack: PackManifest.Pack?
    /// The installed pack, for Remove.
    var installed: RoadPackLibrary.PackStatus?
    var canRemove: Bool
}

/// The rows of Settings → Maps, in order.
struct MapsRows: Hashable, Sendable {
    /// Every manifest pack (or, before any manifest, every installed one).
    var listed: [MapsRow] = []
    /// Installed packs the manifest does not list (developer pushes).
    var other: [MapsRow] = []

    var all: [MapsRow] { listed + other }
    var isEmpty: Bool { listed.isEmpty && other.isEmpty }
}

/// Pure text and rules for Settings → Maps.
enum MapsText {
    static let empty = String(localized: "No road maps installed")
    static let emptyDetail = String(localized: "Road maps are optional. Navigation works without them.")
    static let emptyNoList = String(localized: "Pull down to load the list of maps.")
    static let restartNote = String(localized: "Removal takes effect after the app restarts.")
    static let checking = String(localized: "Checking maps…")
    static let cellularToggle = String(localized: "Use cellular data")
    static let cellularFooter = String(localized: "Maps download over Wi-Fi only unless this is on.")

    /// The one-line network state at the top of Settings → Maps (UX-16).
    struct NetworkLine: Hashable, Sendable {
        var text: String
        var tone: Tone
        var symbol: String
    }

    /// From the downloader's snapshot, the same connection and the same
    /// "Use cellular data" the rows' states come from, so the line and the
    /// rows never disagree. Record pausing downloads is the rows' own state.
    static func networkLine(connection: PackDownloadRules.Connection, cellularAllowed: Bool) -> NetworkLine {
        switch connection {
        case .none:
            NetworkLine(text: String(localized: "Offline"), tone: .caution, symbol: "wifi.slash")
        case .unmetered:
            NetworkLine(text: String(localized: "On Wi-Fi"), tone: .good, symbol: "wifi")
        case .cellular:
            cellularAllowed
                ? NetworkLine(text: String(localized: "On cellular"), tone: .good, symbol: "antenna.radiowaves.left.and.right")
                : NetworkLine(text: String(localized: "On cellular — maps wait for Wi-Fi"), tone: .caution,
                              symbol: "antenna.radiowaves.left.and.right")
        case .meteredWiFi:
            cellularAllowed
                ? NetworkLine(text: String(localized: "On metered Wi-Fi"), tone: .good, symbol: "wifi")
                : NetworkLine(text: String(localized: "On metered Wi-Fi — maps wait for unmetered Wi-Fi"), tone: .caution, symbol: "wifi")
        }
    }

    static func networkLine(_ snapshot: PackDownloader.Snapshot) -> NetworkLine {
        networkLine(connection: snapshot.connection, cellularAllowed: snapshot.cellularAllowed)
    }
    static let otherSection = String(localized: "Other")
    static let neverSection = String(localized: "Not offered on the road")
    static let neverFooter = String(localized: "You chose Never for these regions. Reset to be offered a map again at a stop.")
    static let resetAll = String(localized: "Reset all")

    /// A region the at-a-stop offer must not mention again.
    struct NeverRow: Identifiable, Hashable, Sendable {
        var id: String { name }
        var name: String
        var title: String
    }

    /// Titles from the manifest where known, else the pack name; names order kept.
    static func neverRows(names: [String], manifest: PackManifest?, preferredLanguages: [String]) -> [NeverRow] {
        let titles = Dictionary((manifest?.packs ?? []).map { ($0.name, $0.title(preferredLanguages: preferredLanguages)) },
                                uniquingKeysWith: { first, _ in first })
        return names.map { NeverRow(name: $0, title: titles[$0] ?? $0) }
    }

    static func size(_ bytes: Int64?, locale: Locale = .current) -> String {
        bytes.map { DisplayFormat.megabytes($0, locale: locale) } ?? String(localized: "-- MB")
    }

    /// "OSM 2026-10-01", or "OSM date unknown" (Unix seconds, UTC).
    static func osmDate(timestamp: Int64?) -> String {
        guard let ts = timestamp, ts > 0 else { return String(localized: "OSM date unknown") }
        // The ISO date is fixed on purpose: it is a data stamp, not a calendar date.
        let date = Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.iso8601.year().month().day())
        return String(localized: "OSM \(date)")
    }

    static func osmDate(_ pack: RoadPackLibrary.PackStatus) -> String { osmDate(timestamp: pack.osmTimestamp) }

    static func totalStorage(_ bytes: Int64?, locale: Locale = .current) -> String {
        String(localized: "Storage used: \(size(bytes, locale: locale))")
    }

    /// The credit under the list: the manifest's own text when it has one.
    static func attribution(manifest: PackManifest?) -> String {
        let own = manifest?.attribution.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return own.isEmpty ? RoadsDiagnosticsText.attribution : own
    }

    /// Remove is offered for a stored pack not already marked for removal.
    static func canRemove(_ pack: RoadPackLibrary.PackStatus) -> Bool {
        pack.packName != nil && !pack.pendingRemoval && !pack.inInbox
    }

    static func confirmationTitle(_ row: MapsRow) -> String { String(localized: "Remove \(row.title)?") }

    /// Shown in the confirmation while a Navigate or Record run is active: the
    /// pack is only marked then; the running session keeps using it until the
    /// app restarts, and the file is deleted at the next launch (B5).
    static let removeDuringRunWarning = String(localized: "This map stays in use until you restart the app, then it is removed.")

    static func confirmationMessage(_ row: MapsRow, runActive: Bool = false, locale: Locale = .current) -> String {
        let freed = size(row.installed?.sizeBytes ?? row.sizeBytes, locale: locale)
        // Two full keys, not two sentences joined in code.
        return runActive
            ? String(localized: "This map stays in use until you restart the app, then it is removed. Frees \(freed). Recordings are not affected.")
            : String(localized: "Frees \(freed). Recordings are not affected.")
    }

    static let downloadAgain = String(localized: "Download again")

    /// The notice after Remove, nil when nothing needs saying.
    static func notice(_ outcome: RoadPackLibrary.RemoveOutcome, packName: String) -> String? {
        switch outcome {
        case .deleted: nil
        case .removalPending: String(localized: "\(packName): Removal takes effect after the app restarts.")
        case .notInstalled: String(localized: "\(packName) is not installed.")
        case .failed(let reason): String(localized: "Could not remove \(packName): \(reason)")
        }
    }

    /// The note at the top: "Offline" whenever the path monitor reports no
    /// connection (whatever the age of the cached list: a fresh cache means
    /// no fetch, so no failure either), else the latest failed refresh; nil
    /// when neither. When the connection is `.none` the top network line
    /// (`networkLine`) already says "Offline", so the note then only says the
    /// saved list is shown (nil without one): "Offline" appears once.
    static func listNote(_ refresh: PackManifestService.Refresh, connection: PackDownloadRules.Connection = .unmetered,
                         hasManifest: Bool) -> String? {
        if connection == .none { return hasManifest ? String(localized: "Showing the saved list.") : nil }
        var offline = false
        if case .failed(let failedOffline) = refresh {
            offline = offline || failedOffline
        } else {
            return nil
        }
        switch (offline, hasManifest) {
        case (true, true): return String(localized: "Offline. Showing the saved list.")
        case (true, false): return String(localized: "Offline.")
        case (false, true): return String(localized: "Couldn't update the list. Showing the saved list.")
        case (false, false): return String(localized: "Couldn't update the list.")
        }
    }

    // MARK: Row state

    static func stateText(_ status: MapsRow.Status, locale: Locale = .current) -> String {
        switch status {
        case .notInstalled: String(localized: "Not installed")
        case .queued: String(localized: "Queued")
        case .waitingForWiFi: String(localized: "Waiting for Wi-Fi")
        case .waitingMeteredWiFi: String(localized: "Waiting — this Wi-Fi is metered")
        case .offline: String(localized: "Waiting for network")
        case .downloading(let percent):
            String(localized: "Downloading \((Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale)))")
        case .pausedForRecording: String(localized: "Paused (recording)")
        case .verifying: String(localized: "Verifying")
        case .installed: String(localized: "Installed")
        case .updateAvailable: String(localized: "Update available · from next start")
        case .updatedNextStart: String(localized: "Updated · used from the next start")
        case .failed(let reason): String(localized: "Failed: \(reason)")
        case .removalPending: String(localized: "Removal pending")
        }
    }

    static func tone(_ status: MapsRow.Status) -> Tone {
        switch status {
        case .installed, .updatedNextStart: .good
        case .failed: .bad
        case .updateAvailable, .waitingForWiFi, .waitingMeteredWiFi, .offline, .pausedForRecording, .removalPending: .caution
        case .notInstalled, .queued, .downloading, .verifying: .neutral
        }
    }

    /// "48.0 MB · OSM 2026-10-01 · Installed".
    static func detail(_ row: MapsRow, locale: Locale = .current) -> String {
        [size(row.sizeBytes, locale: locale), osmDate(timestamp: row.osmTimestamp), stateText(row.status, locale: locale)]
            .joined(separator: " · ")
    }

    /// The part of `detail` before the state: the state gets its own colour.
    static func detailPrefix(_ row: MapsRow, locale: Locale = .current) -> String {
        [size(row.sizeBytes, locale: locale), osmDate(timestamp: row.osmTimestamp)].joined(separator: " · ")
    }

    /// Download progress in whole percent, 0...100.
    static func percent(received: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int(min(max(Double(received) / Double(total) * 100, 0), 100))
    }

    /// The icon-only action button's accessibility label.
    static func actionLabel(_ action: MapsRow.Action, title: String) -> String {
        switch action {
        case .download: String(localized: "Download \(title)")
        case .cancel: String(localized: "Cancel download of \(title)")
        case .update: String(localized: "Update \(title)")
        case .downloadAgain: String(localized: "Download \(title) again")
        }
    }

    /// The state of a row from what the app knows: the download, the
    /// installed pack and the manifest's. A download in flight (or failed)
    /// wins; then removal pending, a refused file, a fresh update, an
    /// available update.
    static func status(pack: PackManifest.Pack?, installed: RoadPackLibrary.PackStatus?,
                       download: PackDownloader.State?, updatedNextStart: Bool) -> MapsRow.Status {
        if let download {
            switch download {
            case .queued: return .queued
            case .waitingForWiFi: return .waitingForWiFi
            case .waitingMeteredWiFi: return .waitingMeteredWiFi
            case .offline: return .offline
            case .pausedForRecording: return .pausedForRecording
            case .downloading(let received, let total): return .downloading(percent: percent(received: received, total: total))
            case .verifying: return .verifying
            case .failed(let reason): return .failed(reason)
            }
        }
        guard let installed else { return .notInstalled }
        if installed.pendingRemoval { return .removalPending }
        if !installed.verified { return .failed(installed.refusal ?? String(localized: "not usable")) }
        let update = pack.map {
            PackManifest.updateAvailable(
                installedContentHash: RoadPackStoreRules.parseFileName(installed.name)?.contentHash,
                manifestContentHash: $0.contentHash)
        } ?? false
        if update { return .updateAvailable }
        return updatedNextStart ? .updatedNextStart : .installed
    }

    /// The row's action button. Download and Update need the manifest entry.
    /// `canRestore`: the app can clear a removal mark itself, so a pack the
    /// manifest does not list can be brought back too (B5).
    static func action(status: MapsRow.Status, hasPack: Bool, hasInstalled: Bool, downloadFailed: Bool,
                       canRestore: Bool = false) -> MapsRow.Action? {
        switch status {
        case .queued, .waitingForWiFi, .waitingMeteredWiFi, .offline, .downloading, .pausedForRecording: .cancel
        case .notInstalled: hasPack ? .download : nil
        case .updateAvailable: hasPack ? .update : nil
        case .failed: downloadFailed && hasPack ? (hasInstalled ? .update : .download) : nil
        case .removalPending: hasPack || canRestore ? .downloadAgain : nil
        case .verifying, .installed, .updatedNextStart: nil
        }
    }

    /// Settings → Maps rows: every manifest pack merged with the installed
    /// pack of the same name (`packName == name`), in `PackManifest.listOrder`
    /// (national first, then installed, then by title). Installed packs the
    /// manifest does not list go to `other` (shown with their code); without
    /// any manifest they are all in `listed` with the code as title.
    static func rows(manifest: PackManifest?, installed: [RoadPackLibrary.PackStatus],
                     downloads: PackDownloader.Snapshot, preferredLanguages: [String],
                     locale: Locale = .current, canRestore: Bool = false) -> MapsRows {
        var byName: [String: RoadPackLibrary.PackStatus] = [:]
        for pack in installed where pack.installed {
            guard let name = pack.packName else { continue }
            // A live file wins over a pending-removal one of the same name.
            if let existing = byName[name], !existing.pendingRemoval { continue }
            byName[name] = pack
        }

        func make(name: String, pack: PackManifest.Pack?, installed: RoadPackLibrary.PackStatus?) -> MapsRow {
            let download = downloads.states[name]
            var downloadFailed = false
            if case .failed? = download { downloadFailed = true }
            let status = status(pack: pack, installed: installed, download: download,
                                updatedNextStart: downloads.updatedForNextStart.contains(name))
            return MapsRow(
                id: name, title: pack?.title(preferredLanguages: preferredLanguages) ?? name,
                sizeBytes: pack?.size ?? installed?.sizeBytes,
                osmTimestamp: pack?.osmTimestamp ?? installed?.osmTimestamp, status: status,
                action: action(status: status, hasPack: pack != nil, hasInstalled: installed != nil,
                               downloadFailed: downloadFailed, canRestore: canRestore),
                pack: pack, installed: installed,
                canRemove: installed.map(canRemove) ?? false)
        }

        func ordered(_ rows: [MapsRow], kinds: [String: PackManifest.Pack.Kind]) -> [MapsRow] {
            let entries = rows.map {
                PackManifest.ListEntry(name: $0.id, kind: kinds[$0.id], installed: $0.installed != nil, title: $0.title)
            }
            let order = PackManifest.listOrder(entries, locale: locale).map(\.name)
            let index = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            return order.compactMap { index[$0] }
        }

        guard let manifest else {
            let rows = byName.keys.map { make(name: $0, pack: nil, installed: byName[$0]) }
            return MapsRows(listed: ordered(rows, kinds: [:]), other: [])
        }
        let listed = manifest.packs.map { make(name: $0.name, pack: $0, installed: byName[$0.name]) }
        let kinds = Dictionary(uniqueKeysWithValues: manifest.packs.map { ($0.name, $0.kind) })
        let known = Set(manifest.packs.map(\.name))
        let other = byName.keys.filter { !known.contains($0) }.map { make(name: $0, pack: nil, installed: byName[$0]) }
        return MapsRows(listed: ordered(listed, kinds: kinds), other: ordered(other, kinds: [:]))
    }
}

/// Reads and changes the maps for Settings → Maps: installed packs from the
/// library, the manifest, the downloads.
@MainActor
@Observable
final class MapsModel {
    private(set) var status = RoadPackLibrary.Status.empty
    private(set) var manifest: PackManifest?
    private(set) var downloads = PackDownloader.Snapshot()
    private(set) var listRefresh = PackManifestService.Refresh.idle
    private(set) var rows = MapsRows()
    /// The result of the latest Remove that needs saying.
    private(set) var notice: String?
    @ObservationIgnored private let library: RoadPackLibrary?
    @ObservationIgnored private let manifestService: PackManifestService?
    @ObservationIgnored private let downloader: PackDownloader?
    @ObservationIgnored private let preferredLanguages: @Sendable () -> [String]
    @ObservationIgnored private let defaults: UserDefaults
    /// A Navigate or Record run is active (the app: `RecordingSession.hasActiveRun`).
    @ObservationIgnored private let runActiveCheck: @MainActor () -> Bool
    /// Clears a pack's removal mark without a download (B5;
    /// `RoadPackLibrary.cancelRemoval(name:)`, wired by `AppServices`).
    /// Without it, or when it returns false (the files are gone), Download
    /// again fetches the manifest's pack, which clears the mark when it
    /// installs.
    @ObservationIgnored private let cancelRemoval: (@Sendable (String) async -> Bool)?
    /// The "Use cellular data" UserDefault as last read (Diagnostics shows it
    /// next to the downloader's own value).
    private(set) var cellularSetting = false

    init(library: RoadPackLibrary, manifest: PackManifestService? = nil, downloader: PackDownloader? = nil,
         defaults: UserDefaults = .standard,
         runActive: @escaping @MainActor () -> Bool = { false },
         cancelRemoval: (@Sendable (String) async -> Bool)? = nil,
         preferredLanguages: @escaping @Sendable () -> [String] = { AppLanguage.preferredLanguages }) {
        self.defaults = defaults
        runActiveCheck = runActive
        self.cancelRemoval = cancelRemoval
        cellularSetting = defaults.bool(forKey: MapsSettings.cellularKey)
        self.library = library
        manifestService = manifest
        self.downloader = downloader
        self.preferredLanguages = preferredLanguages
    }

    /// Previews and tests: fixed values.
    init(status: RoadPackLibrary.Status, notice: String? = nil, manifest: PackManifest? = nil,
         downloads: PackDownloader.Snapshot = .init(), refresh: PackManifestService.Refresh = .idle,
         runActive: Bool = false,
         preferredLanguages: @escaping @Sendable () -> [String] = { AppLanguage.preferredLanguages }) {
        runActiveCheck = { runActive }
        cancelRemoval = nil
        self.status = status
        self.notice = notice
        self.manifest = manifest
        self.downloads = downloads
        self.listRefresh = refresh
        library = nil
        manifestService = nil
        downloader = nil
        defaults = .standard
        self.preferredLanguages = preferredLanguages
        rebuild()
    }

    /// A run is active: Remove only marks the pack, and the run loses it (B5).
    var runActive: Bool { runActiveCheck() }

    var listNote: String? { MapsText.listNote(listRefresh, connection: downloads.connection, hasManifest: manifest != nil) }

    private func rebuild() {
        let next = MapsText.rows(manifest: manifest, installed: status.installedPacks, downloads: downloads,
                                 preferredLanguages: preferredLanguages(), canRestore: cancelRemoval != nil)
        if next != rows { rows = next }
    }

    /// The downloads and the setting only (cheap): Diagnostics polls it
    /// while Settings is open; Settings → Maps polls `refreshAll`.
    func refreshDownloads() async {
        let setting = defaults.bool(forKey: MapsSettings.cellularKey)
        if setting != cellularSetting { cellularSetting = setting }
        if let downloader {
            let snapshot = await downloader.snapshot()
            if snapshot != downloads { downloads = snapshot }
        }
    }

    func refreshAll() async {
        guard let library else { return }
        let setting = defaults.bool(forKey: MapsSettings.cellularKey)
        if setting != cellularSetting { cellularSetting = setting }
        let nextStatus = await library.status()
        if nextStatus != status { status = nextStatus }
        if let manifestService {
            let snapshot = await manifestService.snapshot()
            if snapshot.manifest != manifest { manifest = snapshot.manifest }
            if snapshot.refresh != listRefresh { listRefresh = snapshot.refresh }
        }
        if let downloader {
            let snapshot = await downloader.snapshot()
            if snapshot != downloads { downloads = snapshot }
        }
        rebuild()
    }

    /// Kept for callers that only need the installed list.
    func refresh() async { await refreshAll() }

    /// While Maps is visible: rescan once, fetch the list when it is due,
    /// then refresh every 2 s (0.5 s while a download is active).
    func run() async {
        if let library { Task(priority: .utility) { await library.rescan() } }
        if let manifestService {
            Task(priority: .utility) { await manifestService.refresh(force: false) }
        }
        while !Task.isCancelled {
            await refreshAll()
            let active = downloads.states.values.contains(where: \.isActive)
            try? await Task.sleep(for: .milliseconds(active ? 500 : 2000))
        }
    }

    /// Pull to refresh: fetch the list now.
    func pullToRefresh() async {
        if let manifestService { await manifestService.refresh(force: true) }
        if let library { await library.rescan() }
        await refreshAll()
    }

    func perform(_ action: MapsRow.Action, on row: MapsRow) async {
        if action == .downloadAgain, let cancelRemoval, await cancelRemoval(row.id) {
            await refreshAll()
            return
        }
        guard let downloader else { return }
        switch action {
        case .download, .update, .downloadAgain:
            guard let pack = row.pack else { return }
            await downloader.start(pack, isUpdate: action == .update)
        case .cancel:
            await downloader.cancel(name: row.id)
        }
        await refreshAll()
    }

    func remove(_ pack: RoadPackLibrary.PackStatus, title: String? = nil) async {
        guard let library, MapsText.canRemove(pack), let name = pack.packName else { return }
        let outcome = await library.remove(name: name)
        notice = MapsText.notice(outcome, packName: title ?? pack.displayName)
        await refreshAll()
    }

    func dismissNotice() { notice = nil }
}

/// Settings → Maps: the model wired to the plain-values content.
struct MapsScreen: View {
    var model: MapsModel
    /// Owns the "Never for this region" set (UX-8 (2)); nil in previews.
    var offers: PackOfferMonitor?
    @State private var confirming: MapsRow?
    @AppStorage(MapsSettings.cellularKey) private var cellularAllowed = false

    var body: some View {
        MapsContent(
            rows: model.rows, scansCompleted: model.status.scansCompleted, storeBytes: model.status.storeBytes,
            networkLine: MapsText.networkLine(model.downloads), notice: model.notice, listNote: model.listNote, hasManifest: model.manifest != nil,
            attribution: MapsText.attribution(manifest: model.manifest), cellularAllowed: $cellularAllowed,
            neverRows: MapsText.neverRows(names: offers?.neverNames ?? [], manifest: model.manifest,
                                          preferredLanguages: AppLanguage.preferredLanguages),
            onResetNever: { offers?.resetNever($0) }, onResetAllNever: { offers?.resetAllNever() },
            onRemove: { confirming = $0 }, onAction: { action, row in Task { await model.perform(action, on: row) } },
            onDismissNotice: { model.dismissNotice() }
        )
        .refreshable { await model.pullToRefresh() }
        .toolbar {
            if model.rows.all.contains(where: \.canRemove) { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        }
        .confirmationDialog(
            confirming.map(MapsText.confirmationTitle) ?? "", isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible, presenting: confirming
        ) { row in
            Button("Remove", role: .destructive) {
                if let installed = row.installed { Task { await model.remove(installed, title: row.title) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(MapsText.confirmationMessage(row, runActive: model.runActive))
        }
        .task { await model.run() }
        #if DEBUG
        // `-uiFakeRemoveConfirm 1`: opens the Remove confirmation on the first removable row (screenshots).
        .onAppear {
            if UserDefaults.standard.bool(forKey: "uiFakeRemoveConfirm"), confirming == nil {
                confirming = model.rows.all.first(where: \.canRemove)
            }
        }
        #endif
    }
}

/// Plain-values presentation, for previews.
struct MapsContent: View {
    let rows: MapsRows
    var scansCompleted = 1
    let storeBytes: Int64?
    /// The network state above the switch (UX-16); nil hides the line.
    var networkLine: MapsText.NetworkLine?
    var notice: String?
    var listNote: String?
    var hasManifest = false
    var attribution = RoadsDiagnosticsText.attribution
    @Binding var cellularAllowed: Bool
    var neverRows: [MapsText.NeverRow] = []
    var onResetNever: (String) -> Void = { _ in }
    var onResetAllNever: () -> Void = {}
    var onRemove: (MapsRow) -> Void = { _ in }
    var onAction: (MapsRow.Action, MapsRow) -> Void = { _, _ in }
    var onDismissNotice: () -> Void = {}

    var body: some View {
        List {
            cellularSection
            if scansCompleted == 0 {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(MapsText.checking).font(.title3)
                    }
                    .frame(minHeight: 44)
                }
            } else {
                content
            }
            if !neverRows.isEmpty { neverSection }
        }
    }

    /// First section (UX-16): the network state and the switch that explains
    /// every "Waiting" row below, visible without scrolling.
    private var cellularSection: some View {
        Section {
            if let networkLine {
                Label {
                    Text(networkLine.text).font(.body.weight(.semibold))
                } icon: {
                    Image(systemName: networkLine.symbol)
                }
                .foregroundStyle(networkLine.tone.color)
                .accessibilityIdentifier("maps.networkLine")
            }
            Toggle(MapsText.cellularToggle, isOn: $cellularAllowed).frame(minHeight: 44)
        } footer: {
            Text(MapsText.cellularFooter)
        }
    }

    /// Regions marked "Never" on the road; hidden when there are none.
    private var neverSection: some View {
        Section {
            ForEach(neverRows) { item in
                HStack(spacing: 8) {
                    Text(item.title).font(.title3.weight(.semibold))
                    Spacer(minLength: 4)
                    Button { onResetNever(item.name) } label: {
                        Text("Reset").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Offer maps for \(item.title) again")
                }
                .frame(minHeight: 44)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { onResetNever(item.name) } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
                }
            }
            Button(action: onResetAllNever) {
                Text(MapsText.resetAll).frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("Offer maps again for all regions")
        } header: {
            Text(MapsText.neverSection)
        } footer: {
            Text(MapsText.neverFooter)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let notice {
            Section {
                HStack {
                    Text(notice).font(.callout)
                    Spacer(minLength: 8)
                    Button(action: onDismissNotice) {
                        Text("OK").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        if let listNote {
            Section {
                Label(listNote, systemImage: "wifi.slash").font(.callout).foregroundStyle(Tone.caution.color)
            }
        }
        if rows.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MapsText.empty).font(.title3.weight(.semibold))
                    Text(hasManifest ? MapsText.emptyDetail : MapsText.emptyNoList)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        } else {
            if !rows.listed.isEmpty {
                Section {
                    list(rows.listed)
                } footer: {
                    if rows.other.isEmpty { footer }
                }
            }
            if !rows.other.isEmpty {
                Section {
                    list(rows.other)
                } header: {
                    Text(MapsText.otherSection)
                } footer: {
                    footer
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MapsText.totalStorage(storeBytes))
            Text(attribution)
        }
    }

    private func list(_ items: [MapsRow]) -> some View {
        ForEach(items) { item in
            row(item)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if item.canRemove {
                        Button(role: .destructive) { onRemove(item) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .deleteDisabled(!item.canRemove)
        }
        .onDelete { offsets in
            for index in offsets where items[index].canRemove { onRemove(items[index]) }
        }
    }

    private func row(_ item: MapsRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title3.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    (Text(MapsText.detailPrefix(item) + " · ").foregroundStyle(.secondary)
                        + Text(MapsText.stateText(item.status)).fontWeight(.semibold)
                            .foregroundStyle(MapsText.tone(item.status).color))
                        .font(.subheadline).lineLimit(1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MapsText.detailPrefix(item)).foregroundStyle(.secondary)
                        Text(MapsText.stateText(item.status)).fontWeight(.semibold)
                            .foregroundStyle(MapsText.tone(item.status).color)
                    }
                    .font(.subheadline)
                }
                if case .downloading(let percent) = item.status {
                    ProgressView(value: Double(percent), total: 100)
                }
            }
            Spacer(minLength: 4)
            if let action = item.action {
                if action == .downloadAgain {
                    Button { onAction(action, item) } label: {
                        Text(MapsText.downloadAgain)
                            .font(.callout.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(MapsText.actionLabel(action, title: item.title))
                } else {
                    Button { onAction(action, item) } label: {
                        Image(systemName: Self.icon(action))
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(MapsText.actionLabel(action, title: item.title))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func icon(_ action: MapsRow.Action) -> String {
        switch action {
        case .download: "arrow.down.circle"
        case .cancel: "xmark.circle"
        case .update: "arrow.triangle.2.circlepath.circle"
        case .downloadAgain: "arrow.counterclockwise.circle"
        }
    }
}

// MARK: - Previews (synthetic names)

extension RoadPackLibrary.PackStatus {
    static func preview(
        _ name: String, bytes: Int64 = 48_000_000, osm: Int64 = 1_760_000_000, hash: String = "a1b2c3d4",
        coverage: Bool? = true, refusal: String? = nil, pending: Bool = false
    ) -> Self {
        var pack = RoadPackLibrary.PackStatus(
            name: "\(name)-\(hash)00000000.roadpack", verified: refusal == nil && !pending,
            refusal: pending ? RoadPackLibrary.removalPendingText : refusal, sizeBytes: bytes,
            osmTimestamp: osm, hashPrefix: hash, cacheHit: true, verifySeconds: nil)
        pack.packName = name
        pack.hasCoverage = coverage
        pack.pendingRemoval = pending
        return pack
    }
}

extension PackManifest {
    /// A synthetic manifest for previews and screenshots (no real regions).
    static func preview(_ entries: [(name: String, kind: Pack.Kind, title: String, hash: String)]) -> PackManifest {
        let base = URL(string: "https://example.invalid/packs/manifest.json")!
        let packs = entries.enumerated().map { index, entry in
            Pack(name: entry.name, kind: entry.kind, titleUK: entry.title, titleEN: entry.title,
                 bbox: BBox(west: 0, south: 0, east: 1, north: 1),
                 url: URL(string: "/packs/v1/\(entry.name)-\(entry.hash).roadpack", relativeTo: base)!.absoluteURL,
                 size: Int64(20_000_000 + index * 11_000_000),
                 sha256: String(repeating: "0", count: 64), contentHash: entry.hash, formatVersion: 1,
                 osmDate: nil, osmTimestamp: 1_760_000_000)
        }
        return PackManifest(manifestURL: base, generated: "2026-01-01T00:00:00Z", license: "ODbL 1.0",
                            licenseURL: "https://opendatacommons.org/licenses/odbl/1-0/",
                            attribution: "© OpenStreetMap contributors", packs: packs)
    }
}

#Preview("Maps, empty") {
    NavigationStack {
        MapsContent(rows: MapsRows(), storeBytes: 0, cellularAllowed: .constant(false)).navigationTitle("Maps")
    }
}

#Preview("Maps, checking") {
    NavigationStack {
        MapsContent(rows: MapsRows(), scansCompleted: 0, storeBytes: nil, cellularAllowed: .constant(false))
            .navigationTitle("Maps")
    }
}

#Preview("Maps, two packs, no list") {
    NavigationStack {
        MapsContent(
            rows: MapsText.rows(
                manifest: nil,
                installed: [.preview("national", bytes: 120_000_000, hash: "0f0e0d0c", coverage: false),
                            .preview("region-a", hash: "a1b2c3d4")],
                downloads: .init(), preferredLanguages: ["en"]),
            storeBytes: 168_000_000, cellularAllowed: .constant(false)
        ).navigationTitle("Maps")
    }
}

#Preview("Maps, never list") {
    NavigationStack {
        MapsContent(
            rows: MapsRows(), storeBytes: 0, cellularAllowed: .constant(false),
            neverRows: MapsText.neverRows(names: ["region-a", "region-c", "zz-unlisted"], manifest: MapsPreviewData.manifest,
                                          preferredLanguages: ["en"])
        ).navigationTitle("Maps")
    }
}

#Preview("Maps, every state") {
    let model = MapsModel(
        status: MapsPreviewData.status, manifest: MapsPreviewData.manifest, downloads: MapsPreviewData.downloads,
        refresh: .failed(offline: true), preferredLanguages: { ["en"] })
    NavigationStack {
        MapsContent(rows: model.rows, storeBytes: 216_000_000,
                    networkLine: MapsText.networkLine(model.downloads), notice: "region-a: " + MapsText.restartNote,
                    listNote: model.listNote, hasManifest: true, cellularAllowed: .constant(false))
            .navigationTitle("Maps")
    }
}

/// The top section for each connection (UX-16): rows and line from one snapshot.
@MainActor private func networkPreview(_ connection: PackDownloadRules.Connection, cellular: Bool) -> some View {
    let downloads = MapsPreviewData.downloads(connection: connection, cellularAllowed: cellular)
    let model = MapsModel(status: MapsPreviewData.status, manifest: MapsPreviewData.manifest, downloads: downloads,
                          refresh: .ok, preferredLanguages: { ["en"] })
    return NavigationStack {
        MapsContent(rows: model.rows, storeBytes: 216_000_000, networkLine: MapsText.networkLine(downloads),
                    hasManifest: true, cellularAllowed: .constant(cellular))
            .navigationTitle("Maps").navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Maps, on Wi-Fi") { networkPreview(.unmetered, cellular: false) }
#Preview("Maps, on cellular, off") { networkPreview(.cellular, cellular: false) }
#Preview("Maps, on cellular, on") { networkPreview(.cellular, cellular: true) }
#Preview("Maps, metered Wi-Fi, off") { networkPreview(.meteredWiFi, cellular: false) }
#Preview("Maps, offline") { networkPreview(.none, cellular: false) }

/// Synthetic values for the "every state" preview (also used by the DEBUG
/// launch arguments, `DebugFakes`).
enum MapsPreviewData {
    static let manifest = PackManifest.preview([
        ("national", .national, "National roads", "0f0e0d0c00000000"),
        ("region-a", .region, "Region A", "a1b2c3d400000000"),
        ("region-b", .region, "Region B", "5e6f7a8b00000000"),
        ("region-c", .region, "Region C", "1122334400000000"),
        ("region-d", .region, "Region D", "9988776600000000"),
        ("region-e", .region, "Region E", "abcdef0100000000"),
    ])

    static var status: RoadPackLibrary.Status {
        RoadPackLibrary.Status(
            packs: [
                .preview("national", bytes: 41_000_000, hash: "0f0e0d0c", coverage: false),
                .preview("region-a", hash: "a1b2c3d4"),
                .preview("region-b", hash: "00000001"),
                .preview("dev-pack", hash: "77777777"),
            ],
            scansCompleted: 1, storeBytes: 216_000_000)
    }

    /// Downloads as the downloader would show them on `connection` with the
    /// switch `cellularAllowed`: the running and the queued pack both take
    /// the policy's waiting state, so the rows and the network line agree.
    static func downloads(connection: PackDownloadRules.Connection = .unmetered, cellularAllowed: Bool = false)
        -> PackDownloader.Snapshot {
        var snapshot = PackDownloader.Snapshot(connection: connection, cellularAllowed: cellularAllowed)
        let waiting: PackDownloader.State? = switch snapshot.policy {
        case .allowed: nil
        case .waitingForWiFi: .waitingForWiFi
        case .waitingMeteredWiFi: .waitingMeteredWiFi
        case .offline: .offline
        case .pausedForRecording: .pausedForRecording
        }
        snapshot.states = [
            "region-c": waiting ?? .downloading(received: 14_700_000, total: 35_000_000),
            "region-d": .failed("checksum mismatch"),
            "region-e": waiting ?? .queued,
        ]
        return snapshot
    }

    static var downloads: PackDownloader.Snapshot { downloads() }
}
