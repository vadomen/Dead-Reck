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
            isRecording: model.isRecording,
            canScan: model.canScan,
            canSend: model.canSend,
            commandText: $model.commandText,
            isForgetConfirmationPresented: $model.isForgetConfirmationPresented,
            isLinkChangeConfirmationPresented: $model.isLinkChangeConfirmationPresented,
            pendingLinkChange: model.pendingChange,
            actions: .make(model)
        )
    }
}

struct ConsoleActions {
    var scan: () -> Void = {}
    var stopScan: () -> Void = {}
    var connect: (UUID) -> Void = { _ in }
    var disconnect: () -> Void = {}
    var forget: () -> Void = {}
    var confirmLinkChange: (LinkChange) -> Void = { _ in }
    var reinitialise: () -> Void = {}
    /// nil sends the text field's content.
    var send: (String?) -> Void = { _ in }

    /// The model's actions; the link ones are `ConsoleViewModel.linkActions`,
    /// which Settings → OBD adapter uses too (UX-34).
    @MainActor static func make(_ model: ConsoleViewModel) -> ConsoleActions {
        let link = model.linkActions
        return ConsoleActions(
            scan: link.scan, stopScan: link.stopScan, connect: link.connect, disconnect: link.disconnect,
            forget: link.forget, confirmLinkChange: link.confirmLinkChange,
            reinitialise: model.reinitialise, send: { model.send($0) })
    }
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
    var isRecording = false
    var canScan = true
    var canSend = false
    @Binding var commandText: String
    @Binding var isForgetConfirmationPresented: Bool
    @Binding var isLinkChangeConfirmationPresented: Bool
    /// What the dialog confirms, captured when it is presented.
    var pendingLinkChange: LinkChange?
    var actions = ConsoleActions()

    /// Pushed inside Settings' navigation stack (UX-4), which owns the title bar.
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ConsoleLog(lines: lines)
            Divider()
            manualSection
        }
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(LinkConfirmations(
            state: state, discovered: discovered, isRecording: isRecording,
            isForgetPresented: $isForgetConfirmationPresented,
            isLinkChangePresented: $isLinkChangeConfirmationPresented,
            pending: pendingLinkChange, onForget: actions.forget, onConfirm: actions.confirmLinkChange))
    }

    // MARK: Adapter controls

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSimulated { SimulationBadge(text: String(localized: "SIMULATED ADAPTER")) }
            AdapterRow(status: status)
            if let summary {
                Text(summary).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            // One row; where the labels do not fit (Ukrainian), Re-initialise moves to its own row.
            ViewThatFits(in: .horizontal) {
                HStack { linkButtons; Spacer(minLength: 0); reinitialiseButton }
                VStack(alignment: .leading, spacing: 8) { HStack { linkButtons }; reinitialiseButton }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .lineLimit(1)
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

    @ViewBuilder
    private var linkButtons: some View {
        if state == .scanning {
            Button("Stop scan", action: actions.stopScan)
        } else {
            Button("Scan", action: actions.scan)
                .disabled(!canScan)
        }
        Button("Disconnect", action: actions.disconnect)
            .disabled(!ConsoleText.holdsAdapter(state))
        Button("Forget", role: .destructive) { isForgetConfirmationPresented = true }
            .disabled(remembered == nil)
    }

    private var reinitialiseButton: some View {
        Button("Re-initialise", action: actions.reinitialise)
            .disabled(!canReinitialise)
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
                TextField(text: $commandText, prompt: Text(verbatim: "ATI, AT@1, ATDP, ATDPN, ATRV, 010D")) { Text(verbatim: "") }
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { actions.send(nil) }
                Button("Send") { actions.send(nil) }
                    .prominentButton()
                    .disabled(!canSend)
            }
        }
        .padding()
    }
}

/// The Forget and link-change confirmations, shared by Console and Settings →
/// OBD adapter (UX-34) so both ask the same thing in the same words.
struct LinkConfirmations: ViewModifier {
    let state: OBDLinkState
    let discovered: [DiscoveredAdapter]
    let isRecording: Bool
    @Binding var isForgetPresented: Bool
    @Binding var isLinkChangePresented: Bool
    /// What the dialog confirms, captured when it is presented.
    var pending: LinkChange?
    var onForget: () -> Void
    var onConfirm: (LinkChange) -> Void

    private var linkDialog: ConsoleText.LinkChangeDialog {
        var name: String?
        if case .connect(let id) = pending { name = discovered.first { $0.id == id }?.name }
        return ConsoleText.linkChangeDialog(for: pending, link: state, adapterName: name)
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Forget this adapter?", isPresented: $isForgetPresented, titleVisibility: .visible) {
                Button("Forget adapter", role: .destructive, action: onForget)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ConsoleText.forgetMessage(isRecording: isRecording))
            }
            .confirmationDialog(linkDialog.title, isPresented: $isLinkChangePresented, titleVisibility: .visible, presenting: pending) { change in
                Button(linkDialog.confirm, role: linkDialog.confirmIsDestructive ? .destructive : nil) {
                    onConfirm(change)
                }
                Button(linkDialog.cancel, role: .cancel) {}
            } message: { _ in
                Text(linkDialog.message)
            }
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
                    .prominentButton()
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
    // Settings pushes the Console; the preview needs a stack of its own.
    var state: OBDLinkState = .polling(protocolNumber: "A6", voltage: 12.4)
    var summary: String? = "IOS-Vlink · ELM327 v2.3 · protocol A6 · poll 010D0C1 · 9.8 Hz"
    var simulated = true
    var discovered: [DiscoveredAdapter] = []
    var lines = ConsoleLine.previewLines
    var result: ManualResult?
    @State var text = ""
    @State var forget = false
    @State var linkChange = false
    var recording = false

    var body: some View {
        NavigationStack { content }
    }

    private var content: some View {
        ConsoleContent(
            state: state,
            status: AdapterStatus(state),
            summary: summary,
            isSimulated: simulated,
            discovered: discovered,
            remembered: discovered.first?.id,
            lines: lines,
            result: result,
            isRecording: recording,
            canScan: ConsoleText.canScan(link: state, recording: recording),
            canSend: !text.isEmpty,
            commandText: $text,
            isForgetConfirmationPresented: $forget,
            isLinkChangeConfirmationPresented: $linkChange
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

#Preview("Console, recording in progress") {
    ConsolePreviewHost(recording: true)
}
