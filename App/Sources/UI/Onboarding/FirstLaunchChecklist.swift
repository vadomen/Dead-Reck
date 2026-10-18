import Observation
import SwiftUI

/// Remembers that the first-launch checklist (UX-1 (b): mount and
/// orientation) has been confirmed on this phone. Record keeps its own
/// per-drive checklist (`PreDriveChecklist`); this one is asked once.
struct FirstLaunchStore {
    static let key = "firstLaunch.checklistConfirmed"

    var defaults: UserDefaults = .standard

    var isConfirmed: Bool { defaults.bool(forKey: Self.key) }

    func markConfirmed() { defaults.set(true, forKey: Self.key) }
}

/// State of the first-launch checklist sheet. `forced` is the DEBUG
/// `-uiFirstLaunch 1` override: show it even when already confirmed.
@MainActor
@Observable
final class FirstLaunchModel {
    /// The same two confirmations as the pre-drive checklist, same wording.
    var checklist = PreDriveChecklist()
    var isPresented: Bool

    @ObservationIgnored private let store: FirstLaunchStore

    init(store: FirstLaunchStore = FirstLaunchStore(), forced: Bool = false) {
        self.store = store
        isPresented = forced || !store.isConfirmed
    }

    /// Continue is available once both are ticked.
    var canContinue: Bool { checklist.isComplete }

    /// Stores the answer and closes the sheet. Does nothing until both are
    /// ticked.
    func confirm() {
        guard canContinue else { return }
        store.markConfirmed()
        isPresented = false
    }

    /// Settings, "Mount and orientation": the sheet again, unticked.
    func showAgain() {
        checklist = PreDriveChecklist()
        isPresented = true
    }
}

/// The sheet. Plain values and closures, so previews need no model.
struct FirstLaunchChecklistView: View {
    @Binding var checklist: PreDriveChecklist
    var canContinue: Bool
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Before you drive").font(.largeTitle.bold())
            Text("Navigation needs the phone to stay put. Check both, once.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Phone is in a rigid mount", isOn: $checklist.mountConfirmed)
                Toggle("Orientation is fixed for the whole drive", isOn: $checklist.orientationConfirmed)
            }
            .toggleStyle(CheckToggleStyle())
            Spacer()
            Button(action: onContinue) {
                Text("Continue").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 64)
            }
            .prominentButton()
            .disabled(!canContinue)
            Text("You can see this again in Settings.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

#Preview("First launch") {
    FirstLaunchChecklistView(checklist: .constant(PreDriveChecklist()), canContinue: false, onContinue: {})
}

#Preview("First launch, both ticked") {
    FirstLaunchChecklistView(
        checklist: .constant(PreDriveChecklist(mountConfirmed: true, orientationConfirmed: true)),
        canContinue: true, onContinue: {})
}
