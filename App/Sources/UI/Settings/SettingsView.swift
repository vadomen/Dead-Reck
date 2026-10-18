import SwiftUI

/// The Settings tab: Test drive recording, Console and diagnostics. The pushed screens
/// are injected so previews can use fake ones.
struct SettingsScreen<Recording: View, Console: View>: View {
    @Binding var path: [SettingsRoute]
    var info: AppInfo = .read()
    var roads: RoadsDiagnosticsModel
    var onShowChecklist: () -> Void = {}
    @ViewBuilder var recording: () -> Recording
    @ViewBuilder var console: () -> Console
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        SettingsContent(path: $path, info: info, thermal: thermal, roads: roads.value, onShowChecklist: onShowChecklist, recording: recording, console: console)
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermal = ProcessInfo.processInfo.thermalState
            }
            .onAppear { thermal = ProcessInfo.processInfo.thermalState }
            .task { await roads.run() }
    }
}

/// Plain-values presentation of Settings.
struct SettingsContent<Recording: View, Console: View>: View {
    @Binding var path: [SettingsRoute]
    let info: AppInfo
    let thermal: ProcessInfo.ThermalState
    var roads = RoadsDiagnostics()
    var onShowChecklist: () -> Void = {}
    @ViewBuilder var recording: () -> Recording
    @ViewBuilder var console: () -> Console

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: SettingsRoute.recording) {
                        Label("Test drive recording", systemImage: "record.circle")
                            .font(.title3)
                            .frame(minHeight: 44)
                    }
                    Button(action: onShowChecklist) {
                        Label("Mount and orientation", systemImage: "iphone.gen3")
                            .font(.title3)
                            .foregroundStyle(Color.primary)
                            .frame(minHeight: 44)
                    }
                    NavigationLink(value: SettingsRoute.console) {
                        Label("Console", systemImage: "terminal")
                            .font(.title3)
                            .frame(minHeight: 44)
                    }
                }
                Section("Diagnostics") {
                    LabeledContent("Thermal state") {
                        Text(ThermalText.label(thermal))
                            .foregroundStyle(ThermalText.tone(thermal).color)
                            .fontWeight(.semibold)
                    }
                    LabeledContent("Version", value: info.displayVersion)
                    LabeledContent("Build", value: AppInfo.configuration)
                    LabeledContent("Memory", value: MemoryFootprint.format(roads.footprintBytes))
                }
                Section("Road packs") {
                    if roads.library.packs.isEmpty {
                        Text(roads.library.scansCompleted == 0 ? "Looking for packs" : "No packs found")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(roads.library.packs) { pack in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name).font(.body)
                            Text(RoadsDiagnosticsText.state(pack))
                                .fontWeight(.semibold)
                                .foregroundStyle((pack.verified ? Tone.good : Tone.bad).color)
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
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .recording:
                    recording()
                        .navigationTitle("Test drive recording")
                        .navigationBarTitleDisplayMode(.inline)
                case .console:
                    // Sets its own title.
                    console()
                }
            }
        }
    }
}

private let previewPack = RoadPackLibrary.PackStatus(
    name: "region.roadpack", verified: true, refusal: nil, sizeBytes: 48_000_000, osmTimestamp: 1_760_000_000,
    hashPrefix: "a1b2c3d4", cacheHit: true, verifySeconds: 2.4)
private let previewBad = RoadPackLibrary.PackStatus(
    name: "broken.roadpack", verified: false, refusal: "truncated", sizeBytes: 1_000, osmTimestamp: nil,
    hashPrefix: nil, cacheHit: false, verifySeconds: 0.1)

#Preview("Settings") {
    SettingsContent(
        path: .constant([]), info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1"),
        thermal: .nominal,
        roads: RoadsDiagnostics(
            library: .init(packs: [previewPack, previewBad], scansCompleted: 1),
            roads: .init(active: true, packNames: ["region.roadpack"], packHashPrefixes: ["a1b2c3d4"],
                         roadSetHashPrefix: "0f0f0f0f", activeAtSessionS: 12, onRoadShare: 0.93),
            footprintBytes: 210_000_000)
    ) { Text("Recording") } console: { Text("Console") }
}

#Preview("Settings, serious thermal") {
    SettingsContent(
        path: .constant([]), info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1"),
        thermal: .serious
    ) { Text("Recording") } console: { Text("Console") }
}
