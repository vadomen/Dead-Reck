import SwiftUI

/// A row of Settings' main section.
enum SettingsRow: Hashable {
    case route(SettingsRoute)
    /// Pushes the read-only mount text (card 3 of the info cards); no checkboxes.
    case mountAndOrientation
    /// UX-18: re-opens info cards 1-4, read only (not a route).
    case howItWorks
    /// REL-DEMO: "Demo drive (simulated car)", visible in Release without the gate.
    case demoDrive
}

/// Which rows show, in order (UX-14, grouped for the driver in prompt 31):
/// the top group is OBD adapter (UX-34), Maps, Mount and orientation, How FuGPS works; About is
/// its own section after it; then "Developer" (footer "For test drives and
/// diagnostics"): Test drive recording, Sessions and, in Release only behind
/// the Diagnostics gate, Console.
enum SettingsRows {
    static let developerFooter = "For test drives and diagnostics"

    static func driver(adapterAvailable: Bool = SettingsRoute.adapterRowAvailable) -> [SettingsRow] {
        var rows: [SettingsRow] = []
        if adapterAvailable { rows.append(.route(.adapter)) }
        rows += [.route(.maps), .mountAndOrientation, .howItWorks]
        return rows
    }

    static let demoDriveTitle = "Demo drive (simulated car)"

    /// The Developer group by build and gate (REL-EXPORT): Debug shows
    /// everything; Release shows only Demo drive until the 7-tap gate is
    /// open, then Test drive recording, Sessions and Console too.
    static func developerGroup(isDebug: Bool, gateOpen: Bool) -> [SettingsRow] {
        let full = isDebug || gateOpen
        return [.demoDrive] + (full ? developer(showsConsole: true) : [])
    }

    static func developer(showsConsole: Bool) -> [SettingsRow] {
        var rows: [SettingsRow] = [.route(.recording), .route(.sessions)]
        if showsConsole { rows.append(.route(.console)) }
        return rows
    }
}

/// Settings, presented full screen over the map (UX-14): OBD adapter, Maps,
/// mount, About, then Developer (recording, Sessions, Console) and diagnostics. The pushed screens are injected so
/// previews can use fake ones.
struct SettingsScreen<Recording: View, Console: View, Sessions: View, Adapter: View>: View {
    @Binding var path: [SettingsRoute]
    var info: AppInfo = .read()
    var roads: RoadsDiagnosticsModel
    var maps: MapsModel
    var offers: PackOfferMonitor?
    var gate: DeveloperGate
    var onDone: () -> Void = {}
    var onDemoDrive: (() -> Void)?
    var demoRow: DemoDriveRow = .ready
    @ViewBuilder var recording: () -> Recording
    @ViewBuilder var console: () -> Console
    @ViewBuilder var sessions: () -> Sessions
    /// Settings → OBD adapter (UX-34).
    @ViewBuilder var adapter: () -> Adapter
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        SettingsContent(path: $path, info: info, thermal: thermal, roads: roads.value,
                        showsDeveloper: gate.showsDiagnostics, isDebugBuild: gate.isDebug, onDemoDrive: onDemoDrive, demoRow: demoRow,
                        network: NetworkDiagnosticsText.rows(maps.downloads, setting: maps.cellularSetting),
                        versionNote: gate.toast,
                        onVersionTap: { gate.tapVersion() }, onDone: onDone,
                        recording: recording, console: console, maps: { MapsScreen(model: maps, offers: offers) },
                        sessions: sessions, adapter: adapter)
            .task(id: gate.toast) {
                guard gate.toast != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                gate.dismissToast()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermal = ProcessInfo.processInfo.thermalState
            }
            .onAppear { thermal = ProcessInfo.processInfo.thermalState }
            .task { await roads.run() }
            .task(id: gate.showsDiagnostics) {
                // The path and downloads rows (UX-17) are developer-only.
                guard gate.showsDiagnostics else { return }
                while !Task.isCancelled {
                    await maps.refreshDownloads()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

/// Plain-values presentation of Settings.
struct SettingsContent<Recording: View, Console: View, Maps: View, Sessions: View, Adapter: View>: View {
    @Binding var path: [SettingsRoute]
    let info: AppInfo
    let thermal: ProcessInfo.ThermalState
    var roads = RoadsDiagnostics()
    /// The developer rows (Build, Memory, Roads): always in DEBUG, in
    /// Release after 7 taps on Version (`DeveloperGate`).
    var showsDeveloper = true
    /// The build configuration for the Developer group (`SettingsRows.developerGroup`).
    var isDebugBuild = DeveloperGate.buildIsDebug
    /// Demo drive (simulated car): nil until the demo pipeline exists, then the row is disabled.
    var onDemoDrive: (() -> Void)?
    /// Whether Demo drive can start now, or why not (Record active).
    var demoRow: DemoDriveRow = .ready
    /// "Map downloads network" rows (UX-17), shown with the developer rows.
    var network: [NetworkDiagnosticsText.Row] = []
    /// "Developer diagnostics shown/hidden", under Version for a moment.
    var versionNote: String?
    var onVersionTap: () -> Void = {}
    var onDone: () -> Void = {}
    @ViewBuilder var recording: () -> Recording
    @ViewBuilder var console: () -> Console
    @ViewBuilder var maps: () -> Maps
    @ViewBuilder var sessions: () -> Sessions
    @ViewBuilder var adapter: () -> Adapter
    /// Shows the matched road, the on-road share and the engine numbers on
    /// the map; the map's long-press on the speed number sets it too.
    @AppStorage("debug.navStats") private var showNavStats = false
    /// "How FuGPS works": the info cards again, read only (UX-18 (3)).
    @State private var cards = OnboardingModel(mode: .review)
    @State private var showsMount = false

    private var roadsSection: some View {
        Section("Roads") {
            Toggle("Navigation debug on map", isOn: $showNavStats)
            ForEach(roads.library.installedPacks) { pack in
                LabeledContent(pack.displayName, value: RoadsDiagnosticsText.verifyLine(pack))
            }
            ForEach(roads.library.inboxRefusals) { pack in
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.name).font(.body)
                    Text(RoadsDiagnosticsText.state(pack))
                        .fontWeight(.semibold)
                        .foregroundStyle(Tone.bad.color)
                    Text(RoadsDiagnosticsText.detail(pack))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Roads in use", value: RoadsDiagnosticsText.usage(roads.roads))
            if roads.roads.inUse {
                LabeledContent("On road", value: RoadsDiagnosticsText.onRoadShare(roads.roads.onRoadShare))
            }
            if RoadsDiagnosticsText.attributionVisible(packsInUse: roads.roads.packNames.count) {
                Text(RoadsDiagnosticsText.attribution).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var networkSection: some View {
        Section("Map downloads network") {
            ForEach(network) { row in
                LabeledContent(row.label) {
                    Text(row.value)
                        .font(.footnote)
                        .foregroundStyle(row.isProblem ? Tone.bad.color : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var demoEnabled: Bool {
        onDemoDrive != nil && demoRow == .ready
    }

    @ViewBuilder
    private func rows(_ list: [SettingsRow]) -> some View {
        ForEach(list, id: \.self) { row in
            switch row {
            case .route(let route):
                NavigationLink(value: route) {
                    Label(route.title, systemImage: route.systemImage)
                        .font(.title3)
                        .frame(minHeight: 44)
                }
            case .mountAndOrientation:
                Button { showsMount = true } label: {
                    Label("Mount and orientation", systemImage: "iphone.gen3")
                        .font(.title3)
                        .foregroundStyle(Color.primary)
                        .frame(minHeight: 44)
                }
            case .demoDrive:
                VStack(alignment: .leading, spacing: 2) {
                    Button { onDemoDrive?() } label: {
                        Label(SettingsRows.demoDriveTitle, systemImage: "car")
                            .font(.title3)
                            .foregroundStyle(demoEnabled ? Color.primary : Color.secondary)
                            .frame(minHeight: 44)
                    }
                    .disabled(!demoEnabled)
                    if case .blocked(let reason) = demoRow {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            case .howItWorks:
                Button { cards.show() } label: {
                    Label("How FuGPS works", systemImage: "questionmark.circle")
                        .font(.title3)
                        .foregroundStyle(Color.primary)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { rows(SettingsRows.driver()) }
                Section {
                    NavigationLink(value: SettingsRoute.about) {
                        Label(SettingsRoute.about.title, systemImage: SettingsRoute.about.systemImage)
                            .font(.title3)
                            .frame(minHeight: 44)
                    }
                }
                Section {
                    rows(SettingsRows.developerGroup(isDebug: isDebugBuild, gateOpen: showsDeveloper))
                } header: {
                    Text("Developer")
                } footer: {
                    Text(SettingsRows.developerFooter)
                }
                Section("Diagnostics") {
                    LabeledContent("Thermal state") {
                        Text(ThermalText.label(thermal))
                            .foregroundStyle(ThermalText.tone(thermal).color)
                            .fontWeight(.semibold)
                    }
                    if showsDeveloper {
                        LabeledContent("Build", value: AppInfo.configuration)
                        LabeledContent("Memory", value: MemoryFootprint.format(roads.footprintBytes))
                    }
                }
                if showsDeveloper { roadsSection }
                if showsDeveloper, !network.isEmpty { networkSection }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .font(.headline)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .navigationDestination(isPresented: $showsMount) { MountInfoScreen() }
            .fullScreenCover(isPresented: $cards.isPresented) { OnboardingCardsView(model: cards) }
            // Defensive (REL-EXPORT): a route the gate hides never renders,
            // even if something puts it on the path; and it is taken off it.
            .onChange(of: path, initial: true) { _, new in
                let kept = SettingsRoute.permitted(new, isDebug: isDebugBuild, gateOpen: showsDeveloper)
                if kept != new { path = kept }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                if !route.isAllowed(isDebug: isDebugBuild, gateOpen: showsDeveloper) {
                    EmptyView()
                } else {
                switch route {
                case .recording:
                    recording()
                        .navigationTitle("Test drive recording")
                        .navigationBarTitleDisplayMode(.inline)
                case .console:
                    // Sets its own title.
                    console()
                case .maps:
                    maps()
                        .navigationTitle("Maps")
                        .navigationBarTitleDisplayMode(.inline)
                case .sessions:
                    sessions()
                case .adapter:
                    adapter()
                        .navigationTitle("OBD adapter")
                        .navigationBarTitleDisplayMode(.inline)
                case .about:
                    AboutScreen(info: info, versionNote: versionNote, onVersionTap: onVersionTap)
                }
                }
            }
        }
    }
}

extension SettingsRoute {
    /// The test drive recording, Sessions and Console are Developer rows:
    /// in Release they exist only behind the 7-tap gate. The other routes
    /// are always allowed.
    func isAllowed(isDebug: Bool, gateOpen: Bool) -> Bool {
        switch self {
        case .recording, .sessions, .console: isDebug || gateOpen
        case .maps, .adapter, .about: true
        }
    }

    /// `path` without the routes the gate hides.
    static func permitted(_ path: [SettingsRoute], isDebug: Bool, gateOpen: Bool) -> [SettingsRoute] {
        path.filter { $0.isAllowed(isDebug: isDebug, gateOpen: gateOpen) }
    }

    var title: String {
        switch self {
        case .recording: "Test drive recording"
        case .sessions: "Sessions"
        case .maps: "Maps"
        case .adapter: "OBD adapter"
        case .console: "Console"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .recording: "record.circle"
        case .sessions: "list.bullet"
        case .maps: "map"
        case .adapter: "antenna.radiowaves.left.and.right"
        case .console: "terminal"
        case .about: "info.circle"
        }
    }
}

private let previewPack = RoadPackLibrary.PackStatus.preview("region-a")
private var previewInbox: RoadPackLibrary.PackStatus {
    var pack = RoadPackLibrary.PackStatus(
        name: "broken.roadpack", verified: false, refusal: "truncated", sizeBytes: 1_000, osmTimestamp: nil,
        hashPrefix: nil, cacheHit: false, verifySeconds: 0.1)
    pack.inInbox = true
    return pack
}

#Preview("Settings") {
    SettingsContent(
        path: .constant([]), info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1"),
        thermal: .nominal,
        roads: RoadsDiagnostics(
            library: .init(packs: [previewPack, previewInbox], scansCompleted: 1),
            roads: .init(active: true, packNames: ["region-a"], packHashPrefixes: ["a1b2c3d4"],
                         roadSetHashPrefix: "0f0f0f0f", activeAtSessionS: 12, onRoadShare: 0.93),
            footprintBytes: 210_000_000),
        network: NetworkDiagnosticsText.rows(
            PackDownloader.Snapshot(states: ["region-a": .waitingMeteredWiFi, "region-b": .failed("404")],
                                    connection: .meteredWiFi, cellularAllowed: false,
                                    path: PackPath(satisfied: true, usesWiFi: true, expensive: true)),
            setting: true)
    ) { Text("Recording") } console: { Text("Console") } maps: { Text("Maps") } sessions: { Text("Sessions") } adapter: { Text("OBD adapter") }
}

#Preview("Settings, serious thermal") {
    SettingsContent(
        path: .constant([]), info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1"),
        thermal: .serious
    ) { Text("Recording") } console: { Text("Console") } maps: { Text("Maps") } sessions: { Text("Sessions") } adapter: { Text("OBD adapter") }
}

#Preview("Settings, Release (diagnostics hidden)") {
    SettingsContent(
        path: .constant([]), info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1"),
        thermal: .nominal, showsDeveloper: false, versionNote: "Developer diagnostics hidden"
    ) { Text("Recording") } console: { Text("Console") } maps: { Text("Maps") } sessions: { Text("Sessions") } adapter: { Text("OBD adapter") }
}
