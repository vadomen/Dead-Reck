import SwiftUI

/// The Settings tab: Recording, Console and diagnostics. The pushed screens
/// are injected so previews can use fake ones.
struct SettingsScreen<Recording: View>: View {
    @Binding var path: [SettingsRoute]
    var info: AppInfo = .read()
    @ViewBuilder var recording: () -> Recording
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        SettingsContent(path: $path, info: info, thermal: thermal, recording: recording)
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermal = ProcessInfo.processInfo.thermalState
            }
            .onAppear { thermal = ProcessInfo.processInfo.thermalState }
    }
}

/// Plain-values presentation of Settings.
struct SettingsContent<Recording: View>: View {
    @Binding var path: [SettingsRoute]
    let info: AppInfo
    let thermal: ProcessInfo.ThermalState
    @ViewBuilder var recording: () -> Recording

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: SettingsRoute.recording) {
                        Label("Recording", systemImage: "record.circle")
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
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .recording:
                    recording()
                        .navigationTitle("Recording")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }
}

#Preview("Settings") {
    SettingsContent(
        path: .constant([]), info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1"),
        thermal: .nominal
    ) { Text("Recording") }
}

#Preview("Settings, serious thermal") {
    SettingsContent(
        path: .constant([]), info: AppInfo(name: "DriveLogger", version: "0.1.0", build: "1"),
        thermal: .serious
    ) { Text("Recording") }
}
