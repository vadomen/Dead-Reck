import SwiftUI

/// Settings → OBD adapter (UX-34): pair, connect, disconnect and forget the
/// adapter without opening Console. Runs on the Console's model, so every
/// action goes through the same guards (recording-time confirmations, scan
/// gating) and the same confirmation dialogs (`LinkConfirmations`).
struct AdapterSettingsScreen: View {
    @Bindable var model: ConsoleViewModel
    /// True after `AdapterSettingsText.longWait` in the same scanning or
    /// connecting phase.
    @State private var waitedLong = false

    /// The actions this screen offers: `ConsoleViewModel.linkActions`, the
    /// set Console uses too.
    static func actions(_ model: ConsoleViewModel) -> LinkActions { model.linkActions }

    var body: some View {
        let state = model.state
        let remembered = model.remembered
        AdapterSettingsContent(
            state: state,
            status: AdapterSettingsText.status(
                link: state, adapterName: model.adapterName, hasRemembered: remembered != nil,
                foundAdapter: model.discovered.contains(where: OBDLinkService.isLikelyAdapter),
                waitedLong: waitedLong),
            controls: AdapterSettingsText.controls(link: state, recording: model.isRecording, remembered: remembered),
            adapterName: model.adapterName,
            hasRemembered: remembered != nil,
            discovered: model.discovered,
            remembered: remembered,
            isRecording: model.isRecording,
            isSimulated: model.isSimulated,
            isForgetConfirmationPresented: $model.isForgetConfirmationPresented,
            isLinkChangeConfirmationPresented: $model.isLinkChangeConfirmationPresented,
            pendingLinkChange: model.pendingChange,
            actions: Self.actions(model),
            connectRemembered: model.connectRemembered
        )
        .task(id: AdapterSettingsText.waitKey(state)) {
            waitedLong = false
            guard AdapterSettingsText.waitKey(state) != nil else { return }
            try? await Task.sleep(for: AdapterSettingsText.longWait)
            if !Task.isCancelled { waitedLong = true }
        }
    }
}

/// The screen from plain values (previews and DEBUG fakes).
struct AdapterSettingsContent: View {
    let state: OBDLinkState
    let status: AdapterScreenStatus
    let controls: AdapterControls
    var adapterName: String?
    var hasRemembered: Bool
    var discovered: [DiscoveredAdapter] = []
    var remembered: UUID?
    var isRecording = false
    var isSimulated = false
    @Binding var isForgetConfirmationPresented: Bool
    @Binding var isLinkChangeConfirmationPresented: Bool
    var pendingLinkChange: LinkChange?
    var actions: LinkActions
    var connectRemembered: () -> Void

    var body: some View {
        Form {
            Section {
                statusRow
                if isSimulated { SimulationBadge(text: "SIMULATED ADAPTER") }
            }
            Section("Paired adapter") {
                if hasRemembered || controls.canDisconnect {
                    LabeledContent("Name", value: adapterName ?? "Name not known yet")
                        .frame(minHeight: 44)
                } else {
                    Text("None yet. Scan to find yours.")
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
                if controls.canConnect {
                    rowButton("Connect", systemImage: "bolt.horizontal", action: connectRemembered)
                }
                if controls.canDisconnect {
                    rowButton("Disconnect", systemImage: "bolt.horizontal.circle", action: actions.disconnect)
                }
                if controls.canForget {
                    rowButton("Forget adapter", systemImage: "trash", role: .destructive) {
                        isForgetConfirmationPresented = true
                    }
                }
            }
            Section {
                if controls.isScanning {
                    rowButton("Stop scanning", systemImage: "stop.circle", action: actions.stopScan)
                } else {
                    rowButton("Scan for adapters", systemImage: "magnifyingglass", action: actions.scan)
                        .disabled(!controls.canScan)
                }
                ForEach(discovered) { adapter in
                    Button { actions.connect(adapter.id) } label: {
                        HStack {
                            Text(adapter.name).foregroundStyle(.primary)
                            Spacer()
                            if adapter.id == remembered {
                                Label("Paired", systemImage: "checkmark")
                                    .labelStyle(.titleAndIcon)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint(adapter.id == remembered ? "Paired adapter" : "Connect to this adapter")
                }
            } header: {
                Text("Find an adapter")
            } footer: {
                if let note = AdapterSettingsText.scanNote(link: state, recording: isRecording) {
                    Text(note)
                }
            }
            if status.showsHelp {
                Section("If your adapter isn't found") {
                    ForEach(AdapterSettingsText.help, id: \.self) { line in
                        Label(line, systemImage: "circle.fill")
                            .labelStyle(BulletLabelStyle())
                            .font(.subheadline)
                    }
                }
            }
        }
        .modifier(LinkConfirmations(
            state: state, discovered: discovered, isRecording: isRecording,
            isForgetPresented: $isForgetConfirmationPresented,
            isLinkChangePresented: $isLinkChangeConfirmationPresented,
            pending: pendingLinkChange, onForget: actions.forget, onConfirm: actions.confirmLinkChange))
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.symbol)
                .font(.title2)
                .foregroundStyle(status.tone.color)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title).font(.headline)
                if let detail = status.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func rowButton(
        _ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}

/// A small dot instead of the icon's full size: a bullet list.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}

extension AdapterSettingsContent {
    /// DEBUG `-uiFakeAdapter`: the screen from fake inputs, inert controls.
    static func fake(_ fake: AdapterFake) -> AdapterSettingsContent {
        let remembered = fake.hasRemembered ? UUID(uuidString: "00000000-0000-4000-8000-0000000000AD") : nil
        return AdapterSettingsContent(
            state: fake.link,
            status: AdapterSettingsText.status(for: fake),
            controls: AdapterSettingsText.controls(link: fake.link, recording: fake.isRecording, remembered: remembered),
            adapterName: fake.name,
            hasRemembered: fake.hasRemembered,
            discovered: fake.discovered,
            remembered: remembered,
            isRecording: fake.isRecording,
            isForgetConfirmationPresented: .constant(false),
            isLinkChangeConfirmationPresented: .constant(false),
            actions: LinkActions(scan: {}, stopScan: {}, connect: { _ in }, disconnect: {}, forget: {}, confirmLinkChange: { _ in }),
            connectRemembered: {})
    }
}

#Preview("Connected") {
    NavigationStack { AdapterSettingsContent.fake(AdapterFake.parse("connected")!).navigationTitle("OBD adapter") }
}

#Preview("Not found") {
    NavigationStack { AdapterSettingsContent.fake(AdapterFake.parse("notfound")!).navigationTitle("OBD adapter") }
}

#Preview("Bluetooth off") {
    NavigationStack { AdapterSettingsContent.fake(AdapterFake.parse("bluetoothOff")!).navigationTitle("OBD adapter") }
}
