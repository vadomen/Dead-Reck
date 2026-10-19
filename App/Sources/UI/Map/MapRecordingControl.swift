import SwiftUI

/// What the map shows for recording: nothing while idle (Start lives in
/// Settings, "Test drive recording"), or a red dot and the elapsed time while
/// a recording is calibrating or running. Pure.
enum MapRecordingControl: Equatable {
    /// Not recording: no control on the map.
    case none
    /// Recording (or calibrating): red dot, `m:ss`. Tapping asks to stop.
    case indicator(elapsed: String)

    /// `elapsed` is the session clock's `live.elapsed`; no per-second `Date()`.
    static func make(state: RecordingState, elapsed: TimeInterval) -> MapRecordingControl {
        switch state {
        case .calibrating, .recording, .stopping:
            .indicator(elapsed: DisplayFormat.elapsed(elapsed))
        case .idle, .failed:
            .none
        }
    }
}

/// Stop from the map needs a confirmation: a tap only asks. The dialog is
/// the confirmation, so its destructive button stops directly and does not
/// read this state (SwiftUI may reset `isPending` before the action runs).
struct StopConfirmation: Equatable {
    private(set) var isPending = false

    /// The indicator was tapped. Stops nothing.
    mutating func request() { isPending = true }

    /// The dialog went away, by Keep recording, a tap outside, or after Stop.
    mutating func cancel() { isPending = false }
}

/// Recording row (nothing while idle), in the top-left card. Its own view:
/// it alone reads the 16 Hz `session.live`, so the map is not re-rendered.
struct MapRecordingButton: View {
    let session: RecordingSession
    /// Told when the Stop dialog is open: no offer card then (UX-8).
    var offers: PackOfferMonitor?
    /// Runs when "Stop recording" is chosen in the dialog.
    var onStop: @MainActor () async -> Void
    @State private var stop = StopConfirmation()

    var body: some View {
        content(MapRecordingControl.make(state: session.state, elapsed: session.live.elapsed))
            .onChange(of: stop.isPending) { _, open in offers?.isDialogOpen = open }
            .confirmationDialog("Stop recording?", isPresented: pending, titleVisibility: .visible) {
                Button("Stop recording", role: .destructive) {
                    Task { await onStop() }
                }
                Button("Keep recording", role: .cancel) { stop.cancel() }
            } message: {
                Text("The file is closed and saved.")
            }
    }

    private var pending: Binding<Bool> {
        Binding(get: { stop.isPending }, set: { if !$0 { stop.cancel() } })
    }

    @ViewBuilder
    private func content(_ control: MapRecordingControl) -> some View {
        switch control {
        case .none:
            EmptyView()
        case .indicator(let elapsed):
            MapRecordingIndicatorLabel(elapsed: elapsed) { stop.request() }
        }
    }
}

/// Red dot, elapsed time and a stop glyph: the recording row of the top-left
/// card. At least 44 pt tall; the whole row is the tap target.
struct MapRecordingIndicatorLabel: View {
    let elapsed: String
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle().fill(HUDColors.record).frame(width: 14, height: 14)
                Text(elapsed).font(.title3.weight(.bold).monospacedDigit())
                Spacer(minLength: 4)
                Image(systemName: "stop.fill").font(.system(size: 14))
            }
            .foregroundStyle(HUDColors.text)
            // A real 44 pt frame inside the layout; the card has no bottom padding under it.
            .frame(minHeight: MapLayout.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording, \(elapsed). Double tap to stop.")
    }
}

#Preview("Recording indicator") {
    MapRecordingIndicatorLabel(elapsed: "12:34")
        .padding()
        .hudSurface(RoundedRectangle(cornerRadius: 18))
        .padding()
}
