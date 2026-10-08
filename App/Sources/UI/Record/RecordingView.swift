import SwiftUI

/// The Record tab: owns the view model and hands plain values to
/// `RecordingContent`.
struct RecordingScreen: View {
    @Bindable var model: RecordingViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RecordingContent(
            state: model.dashboard,
            gate: model.gate,
            checklist: $model.checklist,
            startError: model.startError,
            lastMark: model.lastMark,
            markCount: model.markCount,
            isMarkSheetPresented: $model.isMarkSheetPresented,
            onStart: { Task { await model.start() } },
            onStop: { model.stop() },
            onMark: { model.mark($0) },
            onRecordWithoutOBD: { model.setRecordWithoutOBD($0) }
        )
        .onAppear { model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }
}

/// Pure presentation of the recording screen.
struct RecordingContent: View {
    let state: DashboardState
    let gate: StartGate
    @Binding var checklist: PreDriveChecklist
    var startError: String?
    var lastMark: String?
    var markCount = 0
    @Binding var isMarkSheetPresented: Bool
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onMark: (String) -> Void = { _ in }
    var onRecordWithoutOBD: @MainActor (Bool) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let badge = state.simulationBadge {
                    SimulationBadge(text: badge)
                }
                StatusBanner(state: state)
                AdapterRow(status: state.adapter)
                HStack(spacing: 12) {
                    SpeedTile(title: "OBD SPEED", subtitle: nil, value: state.obdSpeed, tone: state.obdTone)
                    SpeedTile(title: "GPS", subtitle: "reference", value: state.gpsSpeed, tone: .neutral)
                }
                StatsRow(state: state)
                ForEach(state.notices) { NoticeView(notice: $0) }
                if let startError { NoticeView(notice: .init(text: startError, tone: .bad)) }
                if !state.isActive {
                    StartSection(
                        state: state,
                        gate: gate,
                        checklist: $checklist,
                        onRecordWithoutOBD: onRecordWithoutOBD
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            ControlBar(
                state: state,
                gate: gate,
                lastMark: lastMark,
                onStart: onStart,
                onStop: onStop,
                onMark: { isMarkSheetPresented = true }
            )
        }
        .sheet(isPresented: $isMarkSheetPresented) {
            MarkSheet(onMark: onMark)
                .presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.success, trigger: markCount)
    }
}

// MARK: - Pieces

struct SimulationBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.yellow))
            .accessibilityLabel(text.capitalized)
    }
}

struct StatusBanner: View {
    let state: DashboardState

    var body: some View {
        let headline = state.headline
        VStack(spacing: 2) {
            Text(headline.text)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if state.isActive {
                Text(state.elapsed)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(headline.tone.color))
        .accessibilityElement(children: .combine)
    }
}

struct AdapterRow: View {
    let status: AdapterStatus

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(status.tone.color).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(status.title).font(.title3.weight(.semibold))
                if let detail = status.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

struct SpeedTile: View {
    let title: String
    let subtitle: String?
    let value: String
    let tone: Tone

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(title).font(.subheadline.weight(.bold))
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(value)
                .font(.system(size: 84, weight: .heavy, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("km/h").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tone.color, lineWidth: tone == .neutral ? 0 : 4))
        .accessibilityElement(children: .combine)
    }
}

struct StatsRow: View {
    let state: DashboardState

    var body: some View {
        HStack {
            stat("OBD Hz", state.obdHz)
            stat("Motion Hz", state.motionHz)
            stat("File", state.fileSize)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.title2.weight(.bold).monospacedDigit()).minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct NoticeView: View {
    let notice: DashboardState.Notice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.tone == .bad ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
            Text(notice.text).font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(notice.tone.color)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(notice.tone.color.opacity(0.15)))
    }
}

/// Idle-state content: blocker explanation, the checklist and notes.
struct StartSection: View {
    let state: DashboardState
    let gate: StartGate
    @Binding var checklist: PreDriveChecklist
    var onRecordWithoutOBD: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let blocker = state.blocker {
                NoticeView(notice: .init(text: blocker.message, tone: .bad))
                if blocker.offersRecordWithoutOBD {
                    Toggle(
                        "Record without OBD",
                        isOn: Binding(get: { state.allowsRecordingWithoutOBD }, set: onRecordWithoutOBD)
                    )
                    .font(.headline)
                }
            }
            ChecklistView(checklist: $checklist)
        }
    }
}

struct ChecklistView: View {
    @Binding var checklist: PreDriveChecklist

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before you drive").font(.headline)
            Toggle("Phone is in a rigid mount", isOn: $checklist.mountConfirmed)
            Toggle("Orientation is fixed for the whole drive", isOn: $checklist.orientationConfirmed)
            TextField("Mount note (e.g. vent clip, portrait)", text: $checklist.mountNote)
                .textFieldStyle(.roundedBorder)
            TextField("Vehicle note (e.g. Touareg 2025)", text: $checklist.vehicleNote)
                .textFieldStyle(.roundedBorder)
            Text("After Start, keep the car and phone still for 5 s while it calibrates.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .toggleStyle(CheckToggleStyle())
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

/// Large tap target with an obvious tick.
struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title)
                    .foregroundStyle(configuration.isOn ? Color.green : Color.secondary)
                configuration.label.font(.body.weight(.medium)).multilineTextAlignment(.leading)
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// Start, or Mark and Stop. Pinned to the bottom, 72 pt tall.
struct ControlBar: View {
    let state: DashboardState
    let gate: StartGate
    var lastMark: String?
    var onStart: () -> Void
    var onStop: () -> Void
    var onMark: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if let lastMark {
                Text("Marked: \(lastMark)").font(.callout.weight(.semibold)).foregroundStyle(.green)
            }
            if state.isActive {
                HStack(spacing: 12) {
                    BigButton(title: "MARK", systemImage: "flag.fill", tint: .blue, action: onMark)
                        .disabled(isCalibrating || state.phase == .stopping)
                    BigButton(title: "STOP", systemImage: "stop.fill", tint: .red, action: onStop)
                        .disabled(state.phase == .stopping)
                }
            } else {
                BigButton(title: "START", systemImage: "record.circle", tint: .green, action: onStart)
                    .disabled(!gate.allowsStart)
                if gate == .checklistIncomplete {
                    Text("Confirm both checks above to start")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var isCalibrating: Bool {
        if case .calibrating = state.phase { return true }
        return false
    }
}

struct BigButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 72)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 18).fill(isEnabled ? tint : Color.gray.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mark sheet

struct MarkSheet: View {
    var onMark: (String) -> Void
    @State private var custom = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(MarkPreset.all, id: \.self) { preset in
                            Button { onMark(preset) } label: {
                                Text(preset.capitalized)
                                    .font(.title3.weight(.bold))
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .foregroundStyle(.white)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Custom marker", text: $custom)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.send)
                            .onSubmit(sendCustom)
                        Button("Mark", action: sendCustom)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding()
            }
            .navigationTitle("Add marker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func sendCustom() {
        onMark(custom)
        custom = ""
    }
}

// MARK: - Previews

extension DashboardState {
    static func preview(
        phase: Phase = .recording,
        adapter: OBDLinkState = .polling(protocolNumber: "A6", voltage: 12.4),
        obd: String = "62",
        gps: String = "61",
        notices: [Notice] = [],
        blocker: StartBlockerNotice? = nil,
        badge: String? = nil
    ) -> DashboardState {
        var s = DashboardState()
        s.phase = phase
        s.adapter = AdapterStatus(adapter)
        s.obdSpeed = obd
        s.gpsSpeed = gps
        s.obdTone = s.adapter.isPolling ? .good : (s.isActive ? .bad : .neutral)
        s.obdHz = "9.8"
        s.motionHz = "99.7"
        s.elapsed = "12:34"
        s.fileSize = "48.2 MB"
        s.notices = notices
        s.blocker = blocker
        s.simulationBadge = badge
        return s
    }
}

private struct RecordingPreviewHost: View {
    var state: DashboardState
    var gate: StartGate = .ready
    @State var checklist = PreDriveChecklist(mountConfirmed: true, orientationConfirmed: true, mountNote: "Vent clip", vehicleNote: "Touareg 2025")
    @State var sheet = false

    var body: some View {
        RecordingContent(state: state, gate: gate, checklist: $checklist, isMarkSheetPresented: $sheet)
    }
}

#Preview("Recording") {
    RecordingPreviewHost(state: .preview())
}

#Preview("Calibrating") {
    RecordingPreviewHost(state: .preview(phase: .calibrating(secondsLeft: 4), obd: "0", gps: "--"))
}

#Preview("Idle, ready") {
    RecordingPreviewHost(state: .preview(phase: .idle, obd: "0", gps: "--", badge: "SIMULATED ADAPTER · SIMULATED SENSORS"))
}

#Preview("Bluetooth unavailable") {
    let blocker = StartBlockerNotice(.obdNotReady)
    RecordingPreviewHost(
        state: .preview(phase: .idle, adapter: .unavailable(reason: "Bluetooth is off"), obd: "--", gps: "--", blocker: blocker),
        gate: .blocked(blocker!)
    )
}

#Preview("Motion unavailable, adapter lost") {
    RecordingPreviewHost(state: .preview(
        phase: .recording,
        adapter: .reconnecting(attempt: 2),
        obd: "--",
        notices: [
            .init(text: "Motion unavailable: Motion & Fitness access denied", tone: .caution),
            .init(text: "No background location session. Recording may pause while the phone is locked.", tone: .caution),
        ]
    ))
}

#Preview("Low disk") {
    RecordingPreviewHost(state: .preview(notices: [.init(text: "Low disk space (180 MB free). Recording stops automatically when it runs out.", tone: .bad)]))
}

#Preview("Failed") {
    RecordingPreviewHost(
        state: .preview(phase: .failed(reason: "no space left on device", unwrittenEvents: 1234), adapter: .idle, obd: "--", gps: "--"),
        gate: .checklistIncomplete
    )
}

#Preview("Mark sheet") {
    MarkSheet(onMark: { _ in })
}
