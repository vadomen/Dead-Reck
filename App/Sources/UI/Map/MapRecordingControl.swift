import SwiftUI

/// What the map shows for recording: Start while idle, or a red dot and the
/// elapsed time while a recording is calibrating or running. Pure.
enum MapRecordingControl: Equatable {
    /// Not recording: a Start button that opens Settings, Recording.
    case start
    /// Recording (or calibrating): red dot, `m:ss`. Tapping asks to stop.
    case indicator(elapsed: String)

    /// `elapsed` is the session clock's `live.elapsed`; no per-second `Date()`.
    static func make(state: RecordingState, elapsed: TimeInterval) -> MapRecordingControl {
        switch state {
        case .calibrating, .recording, .stopping:
            .indicator(elapsed: DisplayFormat.elapsed(elapsed))
        case .idle, .failed:
            .start
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

/// Start button or recording indicator, bottom left of the map. Its own view:
/// it alone reads the 16 Hz `session.live`, so the map is not re-rendered.
struct MapRecordingButton: View {
    let session: RecordingSession
    var onStart: () -> Void
    /// Runs when "Stop recording" is chosen in the dialog.
    var onStop: @MainActor () async -> Void
    @State private var stop = StopConfirmation()

    var body: some View {
        content(MapRecordingControl.make(state: session.state, elapsed: session.live.elapsed))
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
        case .start:
            Button(action: onStart) {
                Label("Start", systemImage: "record.circle")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 56)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            }
        case .indicator(let elapsed):
            MapRecordingIndicatorLabel(elapsed: elapsed) { stop.request() }
        }
    }
}

/// Red dot and elapsed time; a 56 pt tap target.
struct MapRecordingIndicatorLabel: View {
    let elapsed: String
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle().fill(Color.red).frame(width: 16, height: 16)
                Text(elapsed).font(.title3.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.red.opacity(0.6), lineWidth: 2))
        }
        .accessibilityLabel("Recording, \(elapsed). Double tap to stop.")
    }
}

#Preview("Recording indicator") {
    MapRecordingIndicatorLabel(elapsed: "12:34")
        .padding()
}
