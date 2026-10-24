import DriveLoggerCore
import Foundation
import Observation

/// Remembers that the first-launch maps step (UX-8 (1)) is done: the user
/// confirmed a list or chose "Download maps later". Only that flag is
/// stored: nothing about location, and the chosen packs are only what the
/// downloader and the library keep anyway. Shown after the UX-1 checklist
/// (`FirstLaunchStore`); the UI sequences the two.
struct FirstLaunchMapsStore {
    static let key = "firstLaunch.mapsDone"
    /// DEBUG `-uiFirstLaunchMaps 1`: show the step even when done (and, with
    /// no `-uiCoarseFix`, without any fix: `CoarseLocation.makeSource`).
    static let forceKey = "uiFirstLaunchMaps"

    var defaults: UserDefaults = .standard

    var isDone: Bool { defaults.bool(forKey: Self.key) }

    func markDone() { defaults.set(true, forKey: Self.key) }
}

/// The first-launch maps list (UX-8 (1), docs/BACKLOG_UX.md): the manifest's
/// packs with sizes, `national` always preselected, the region containing a
/// usable coarse fix preselected, its neighbours listed next to it (not
/// preselected). The user edits and confirms; nothing downloads before
/// `confirm()`.
///
/// - **The list**: the cached manifest at once when there is one, then a
///   fetch (`refresh(force: true)`); the fresh list replaces it. Neither:
///   `listState == .noList`, and only "Download maps later" applies.
/// - **The fix** runs in parallel and never blocks the list
///   (`CoarseFixRequest`: ≤ 10 s, When In Use already granted, else none).
///   It is held only to compute the suggestion: never stored, logged or
///   sent; the request's task is dropped when the step closes.
/// - **User edits win.** Until the user toggles a row, the selection and
///   order follow the suggestion (national; plus the region once a usable
///   fix arrives). After the first toggle a late fix changes NOTHING, not
///   the selection and not the order (rows must not move under the
///   user's finger); a later manifest keeps the user's selection (names
///   still listed) and order, new packs appended in list order.
/// - **Installed packs** are listed as installed, never preselected and
///   never queued again.
/// - `confirm()` queues the selected packs in list order in
///   `PackDownloader`, whose network policy applies (Wi-Fi only unless
///   cellular is allowed; offline waits). `network` tells the button which
///   wording applies.
@MainActor
@Observable
final class FirstLaunchMapsModel {
    enum ListState: Hashable, Sendable {
        case loading
        case ready
        /// No fetched and no cached manifest: "Download maps later" only.
        case noList
    }

    enum Role: Hashable, Sendable {
        case national
        /// The region containing the fix.
        case region
        /// Listed next to the region (bbox within ~20 km), not preselected.
        case neighbour
        case other
    }

    /// What a download would do now (`PackDownloadRules.networkState`).
    enum Network: Hashable, Sendable {
        /// Wi-Fi, or cellular with "Use cellular data" on: starts at once.
        case ready
        /// Cellular without permission: "will wait for Wi-Fi" (and offer
        /// `useCellular()`).
        case waitsForWiFi
        /// No network: queued, starts when online.
        case offline
    }

    enum FixState: Hashable, Sendable {
        case waiting
        /// A usable fix arrived; `region` nil when no region bbox contains it.
        case found(region: String?)
        /// No usable fix (no permission, timeout).
        case none
    }

    struct Row: Identifiable, Hashable, Sendable {
        /// The pack name.
        var id: String
        /// In the app language (`Pack.title(preferredLanguages:)`).
        var title: String
        var sizeBytes: Int64
        var role: Role
        var isSelected: Bool
        /// Already in the store: shown, not selectable.
        var isInstalled: Bool
    }

    private(set) var listState = ListState.loading
    private(set) var rows: [Row] = []
    private(set) var network = Network.offline
    private(set) var fixState = FixState.waiting
    /// The permission is being asked: the view says why, above the list,
    /// before and while the system prompt shows. The list stays editable.
    private(set) var asksLocation = false
    private(set) var isPresented: Bool
    /// The user toggled a row: a late fix no longer changes anything.
    private(set) var userEdited = false

    var selectedCount: Int { rows.filter(\.isSelected).count }
    var selectedBytes: Int64 { rows.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes } }
    /// "Download" applies: a list with at least one selected row.
    var canConfirm: Bool { listState == .ready && selectedCount > 0 }

    @ObservationIgnored private let store: FirstLaunchMapsStore
    @ObservationIgnored private let manifestService: PackManifestService
    @ObservationIgnored private let downloader: PackDownloader
    @ObservationIgnored private let installedNames: @Sendable () async -> Set<String>
    @ObservationIgnored private let coarseFix: @MainActor () async -> CoarseFixRequest.Result?
    @ObservationIgnored private let authorization: @MainActor () -> CoarseAuthorization
    @ObservationIgnored private let requestAuthorization: @MainActor () async -> CoarseAuthorization
    /// How long the explanation shows before the system prompt.
    @ObservationIgnored private let askDelay: Duration
    @ObservationIgnored private let preferredLanguages: @Sendable () -> [String]
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var packs: [PackManifest.Pack] = []
    @ObservationIgnored private var installed: Set<String> = []
    @ObservationIgnored private var selected: Set<String> = []
    @ObservationIgnored private var fix: CoarseFixRequest.Result?
    /// The suggestion the current order and roles come from.
    @ObservationIgnored private var suggestion: PackRegionChoice.Suggestion?
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var fixTask: Task<Void, Never>?

    /// - Parameters:
    ///   - installedNames: names of packs in the store (not pending removal).
    ///   - coarseFix: the first usable coarse fix, nil when none.
    ///   - forced: DEBUG `-uiFirstLaunchMaps 1`: present even when done.
    init(store: FirstLaunchMapsStore = FirstLaunchMapsStore(), manifest: PackManifestService,
         downloader: PackDownloader, installedNames: @escaping @Sendable () async -> Set<String> = { [] },
         coarseFix: @escaping @MainActor () async -> CoarseFixRequest.Result?,
         authorization: @escaping @MainActor () -> CoarseAuthorization = { .allowed },
         requestAuthorization: @escaping @MainActor () async -> CoarseAuthorization = { .allowed },
         askDelay: Duration = .seconds(1.5),
         preferredLanguages: @escaping @Sendable () -> [String] = { AppLanguage.preferredLanguages },
         locale: Locale = .current, now: @escaping @MainActor () -> Date = { Date() }, forced: Bool = false) {
        self.store = store
        manifestService = manifest
        self.downloader = downloader
        self.installedNames = installedNames
        self.coarseFix = coarseFix
        self.authorization = authorization
        self.requestAuthorization = requestAuthorization
        self.askDelay = askDelay
        self.preferredLanguages = preferredLanguages
        self.locale = locale
        self.now = now
        isPresented = forced || !store.isDone
    }

    /// The app's model: the app's manifest, downloader and library, and the
    /// coarse source of `CoarseLocation.makeSource` (DEBUG overrides).
    /// `manifest`: DEBUG screenshots pass a synthetic one.
    convenience init(services: AppServices, manifest: PackManifestService? = nil, forced: Bool = false) {
        let library = services.roadPacks
        let source = CoarseLocation.makeSource()
        self.init(manifest: manifest ?? services.manifest, downloader: services.downloader,
                  installedNames: { await FirstLaunchMapsModel.installedNames(library) },
                  coarseFix: { await CoarseFixRequest(source: source).run() },
                  authorization: { source.authorization }, requestAuthorization: { await source.requestAuthorization() },
                  forced: forced)
    }

    nonisolated static func installedNames(_ library: RoadPackLibrary) async -> Set<String> {
        Set(await library.status().installedPacks.filter { !$0.pendingRemoval }.compactMap(\.packName))
    }

    // MARK: Lifecycle

    /// Starts the list and the fix (once), then refreshes `network` every
    /// second while presented. The view's `.task`.
    func run() async {
        start()
        while !Task.isCancelled, isPresented {
            await refreshNetwork()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Starts loading the list and, in parallel, the coarse fix. Idempotent.
    func start() {
        guard isPresented, listTask == nil else { return }
        listTask = Task { await loadList() }
        fixTask = Task {
            let result = await locate()
            guard !Task.isCancelled else { return }
            applyFix(result)
        }
    }

    /// The fix, after the permission: not determined: say why, then ask once
    /// (When In Use); the 10 s window starts after the answer. Denied or
    /// restricted: never asked, no fix. Allowed: the fix at once. The list is
    /// editable throughout.
    private func locate() async -> CoarseFixRequest.Result? {
        switch authorization() {
        case .denied:
            return nil
        case .allowed:
            break
        case .notDetermined:
            asksLocation = true
            if askDelay > .zero { try? await Task.sleep(for: askDelay) }
            let answer = Task.isCancelled ? CoarseAuthorization.denied : await requestAuthorization()
            asksLocation = false
            guard answer == .allowed else { return nil }
        }
        return await coarseFix()
    }

    /// Tests: waits for the list and the fix.
    func waitUntilLoaded() async {
        await listTask?.value
        await fixTask?.value
    }

    /// Tests: waits for the list only.
    func waitForList() async {
        await listTask?.value
    }

    private func loadList() async {
        if let cached = await manifestService.cachedManifest() { apply(cached.packs) }
        installed = await installedNames()
        if !packs.isEmpty { rebuild() }
        await manifestService.refresh(force: true)
        if let fresh = await manifestService.snapshot().manifest {
            apply(fresh.packs)
        } else if packs.isEmpty {
            listState = .noList
        }
        await refreshNetwork()
    }

    // MARK: Inputs

    private func apply(_ next: [PackManifest.Pack]) {
        packs = next
        let names = Set(next.map(\.name))
        if userEdited {
            selected.formIntersection(names)
            let kept = order.filter(names.contains)
            let fresh = PackRegionChoice.listOrder(next, suggestion: currentSuggestion(), restOrder: titleOrder)
                .map(\.name).filter { !kept.contains($0) }
            order = kept + fresh
        } else {
            resuggest()
        }
        listState = .ready
        rebuild()
    }

    private func applyFix(_ result: CoarseFixRequest.Result?) {
        fix = result
        // The region named here is the fix's, whatever the list shows.
        fixState = result == nil ? .none : .found(region: currentSuggestion().region)
        // A late fix never overrides the user's edits (selection or order).
        guard !userEdited, !packs.isEmpty else { return }
        resuggest()
        rebuild()
    }

    private func currentSuggestion() -> PackRegionChoice.Suggestion {
        PackRegionChoice.suggest(packs: packs, fix: fix?.fix, requestedAt: fix?.requestedAt ?? now())
    }

    /// Selection and order from the suggestion (before any user edit).
    private func resuggest() {
        let next = currentSuggestion()
        suggestion = next
        selected = Set(next.preselected).subtracting(installed)
        order = PackRegionChoice.listOrder(packs, suggestion: next, restOrder: titleOrder).map(\.name)
        if fix != nil { fixState = .found(region: next.region) }
    }

    private var titleOrder: (PackManifest.Pack, PackManifest.Pack) -> Bool {
        let languages = preferredLanguages()
        let locale = self.locale
        return { a, b in
            switch a.title(preferredLanguages: languages)
                .compare(b.title(preferredLanguages: languages), options: .caseInsensitive, range: nil, locale: locale) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.name < b.name
            }
        }
    }

    private func rebuild() {
        let byName = Dictionary(packs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let languages = preferredLanguages()
        let region = suggestion?.region
        let neighbours = Set(suggestion?.neighbours.map(\.name) ?? [])
        selected.subtract(installed)
        let next = order.compactMap { name -> Row? in
            guard let pack = byName[name] else { return nil }
            let role: Role = pack.kind == .national ? .national
                : name == region ? .region : neighbours.contains(name) ? .neighbour : .other
            return Row(id: name, title: pack.title(preferredLanguages: languages), sizeBytes: pack.size, role: role,
                       isSelected: selected.contains(name), isInstalled: installed.contains(name))
        }
        if next != rows { rows = next }
    }

    /// Reads the downloader's connection and the cellular switch.
    func refreshNetwork() async {
        // The downloader's own connection and switch (UX-17): the wording is
        // what the downloads will do, whatever the UserDefault says.
        let snapshot = await downloader.snapshot()
        // No recording runs during the first-launch step.
        let next: Network = switch PackDownloadRules.networkState(
            connection: snapshot.connection, cellularAllowed: snapshot.cellularAllowed, recordActive: false) {
        case .allowed: .ready
        case .waitingForWiFi, .waitingMeteredWiFi: .waitsForWiFi
        case .offline, .pausedForRecording: .offline
        }
        if next != network { network = next }
    }

    // MARK: User actions

    /// Toggles a row (installed rows cannot be selected). From now on a
    /// late fix changes nothing.
    func toggle(_ name: String) {
        setSelected(name, !selected.contains(name))
    }

    func setSelected(_ name: String, _ isSelected: Bool) {
        guard packs.contains(where: { $0.name == name }), !installed.contains(name) else { return }
        userEdited = true
        if isSelected { selected.insert(name) } else { selected.remove(name) }
        rebuild()
    }

    /// Queues the selected packs (list order) and closes the step. Nothing
    /// is queued without this call.
    func confirm() async {
        guard canConfirm else { return }
        let byName = Dictionary(packs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let chosen = rows.filter(\.isSelected).compactMap { byName[$0.id] }
        for pack in chosen { await downloader.start(pack) }
        close()
    }

    /// "Use cellular data": the Settings → Maps switch, and the downloader.
    func useCellular() async {
        store.defaults.set(true, forKey: MapsSettings.cellularKey)
        await downloader.setCellularAllowed(true)
        await refreshNetwork()
    }

    /// "Download maps later": closes the step; nothing is queued.
    func later() {
        close()
    }

    private func close() {
        store.markDone()
        isPresented = false
        asksLocation = false
        listTask?.cancel()
        fixTask?.cancel()
    }
}
