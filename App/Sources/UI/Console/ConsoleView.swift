import SwiftUI

struct ConsoleScreen: View {
    @Bindable var model: ConsoleViewModel

    var body: some View {
        ConsoleContent(
            state: model.state,
            status: model.status,
            summary: model.summary,
            isSimulated: model.isSimulated,
            discovered: model.discovered,
            remembered: model.remembered,
            lines: model.lines,
            result: model.result,
            canReinitialise: model.canReinitialise,
            canSend: model.canSend,
            commandText: $model.commandText,
            isForgetConfirmationPresented: $model.isForgetConfirmationPresented,
            actions: .init(
                scan: model.scan,
                stopScan: model.stopScan,
                connect: model.connect,
                disconnect: model.disconnect,
                forget: model.forget,
                reinitialise: model.reinitialise,
                send: { model.send($0) }
            )
        )
    }
}

struct ConsoleActions {
    var scan: () -> Void = {}
    var stopScan: () -> Void = {}
    var connect: (UUID) -> Void = { _ in }
    var disconnect: () -> Void = {}
    var forget: () -> Void = {}
    var reinitialise: () -> Void = {}
    /// nil sends the text field's content.
    var send: (String?) -> Void = { _ in }
}

struct ConsoleContent: View {
    let state: OBDLinkState
    let status: AdapterStatus
    var summary: String?
    var isSimulated = false
    let discovered: [DiscoveredAdapter]
    var remembered: UUID?
    let lines: [ConsoleLine]
    var result: ManualResult?
    var canReinitialise = true
    var canSend = false
    @Binding var commandText: String
    @Binding var isForgetConfirmationPresented: Bool
    var actions = ConsoleActions()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                ConsoleLog(lines: lines)
                Divider()
                manualSection
            }
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Forget this adapter?", isPresented: $isForgetConfirmationPresented, titleVisibility: .visible) {
                Button("Forget adapter", role: .destructive, action: actions.forget)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The app will stop reconnecting to it. You can pick it again from a scan.")
            }
        }
    }

    // MARK: Adapter controls

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSimulated { SimulationBadge(text: "SIMULATED ADAPTER") }
            AdapterRow(status: status)
            if let summary {
                Text(summary).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                if state == .scanning {
                    Button("Stop scan", action: actions.stopScan)
                } else {
                    Button("Scan", action: actions.scan)
                        .disabled(isUnavailable)
                }
                Button("Disconnect", action: actions.disconnect)
                    .disabled(!isConnectedish)
                Button("Forget", role: .destructive) { isForgetConfirmationPresented = true }
                    .disabled(remembered == nil)
                Spacer(minLength: 0)
                Button("Re-initialise", action: actions.reinitialise)
                    .disabled(!canReinitialise)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if !discovered.isEmpty {
                ForEach(discovered) { adapter in
                    Button { actions.connect(adapter.id) } label: {
                        HStack {
                            Image(systemName: adapter.id == remembered ? "star.fill" : "antenna.radiowaves.left.and.right")
                            Text(adapter.name).font(.body.weight(.medium))
                            Spacer()
                            Text("\(adapter.rssi) dBm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    private var isConnectedish: Bool {
        switch state {
        case .idle, .scanning, .unavailable: false
        default: true
        }
    }

    // MARK: Manual command

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let result {
                ResultView(result: result, onReinitialise: result.kind == .desynchronised ? actions.reinitialise : nil)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(ConsoleText.quickCommands, id: \.self) { command in
                        Button(command) { actions.send(command) }
                            .font(.callout.monospaced().weight(.semibold))
                            .buttonStyle(.bordered)
                    }
                }
            }
            HStack {
                TextField("ATI, AT@1, ATDP, ATDPN, ATRV, 010D", text: $commandText)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { actions.send(nil) }
                Button("Send") { actions.send(nil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
        }
        .padding()
    }
}

struct ResultView: View {
    let result: ManualResult
    var onReinitialise: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title).font(.callout.monospaced().weight(.bold)).foregroundStyle(result.tone.color)
            if let detail = result.detail {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let onReinitialise {
                Button("Re-initialise", systemImage: "arrow.clockwise", action: onReinitialise)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(result.tone.color.opacity(0.12)))
    }
}

/// Monospaced log that follows the newest line.
struct ConsoleLog: View {
    let lines: [ConsoleLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(ConsoleText.prefix(line.direction)).foregroundStyle(color(line.direction)).bold()
                            Text(line.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .id(line.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .background(Color(.secondarySystemBackground))
            .onChange(of: lines.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .overlay {
                if lines.isEmpty {
                    Text("No traffic yet").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(_ direction: ConsoleLine.Direction) -> Color {
        switch direction {
        case .tx: .blue
        case .rx: .green
        case .status: .orange
        }
    }
}

// MARK: - Previews

extension ConsoleLine {
    static let previewLines: [ConsoleLine] = [
        .init(id: 1, direction: .status, text: "ble: connected (vgate)", uptime: 100),
        .init(id: 2, direction: .tx, text: "ATZ", uptime: 100.1),
        .init(id: 3, direction: .rx, text: "ELM327 v2.3", uptime: 100.9),
        .init(id: 4, direction: .tx, text: "ATDPN", uptime: 101.2),
        .init(id: 5, direction: .rx, text: "A6", uptime: 101.3),
        .init(id: 6, direction: .tx, text: "010D0C1", uptime: 101.6),
        .init(id: 7, direction: .rx, text: "7E8 04 41 0D 3C 0C 1A F8", uptime: 101.7),
        .init(id: 8, direction: .status, text: "link desynchronised: no prompt for ATRV, written off", uptime: 120),
    ]
}

private struct ConsolePreviewHost: View {
    var state: OBDLinkState = .polling(protocolNumber: "A6", voltage: 12.4)
    var summary: String? = "IOS-Vlink · ELM327 v2.3 · protocol A6 · poll 010D0C1 · 9.8 Hz"
    var simulated = true
    var discovered: [DiscoveredAdapter] = []
    var lines = ConsoleLine.previewLines
    var result: ManualResult?
    @State var text = ""
    @State var forget = false

    var body: some View {
        ConsoleContent(
            state: state,
            status: AdapterStatus(state),
            summary: summary,
            isSimulated: simulated,
            discovered: discovered,
            remembered: discovered.first?.id,
            lines: lines,
            result: result,
            canSend: !text.isEmpty,
            commandText: $text,
            isForgetConfirmationPresented: $forget
        )
    }
}

#Preview("Console, polling") {
    ConsolePreviewHost(result: ConsoleText.result(for: .forbiddenCommand("ATZ"), command: "ATZ"))
}

#Preview("Console, desynchronised") {
    ConsolePreviewHost(result: ConsoleText.result(for: .desynchronised, command: "ATRV"))
}

#Preview("Console, Bluetooth unavailable") {
    ConsolePreviewHost(state: .unavailable(reason: "Bluetooth is off"), summary: nil, simulated: false, lines: [])
}

#Preview("Console, scan results") {
    ConsolePreviewHost(
        state: .scanning,
        summary: nil,
        simulated: false,
        discovered: [
            DiscoveredAdapter(id: UUID(), name: "IOS-Vlink", rssi: -58),
            DiscoveredAdapter(id: UUID(), name: "Headphones", rssi: -80),
        ],
        lines: []
    )
}
