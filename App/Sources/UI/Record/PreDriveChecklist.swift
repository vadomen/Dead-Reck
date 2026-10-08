import Foundation

/// The pre-drive checklist: two confirmations that are asked again for every
/// drive, and two notes that are remembered between drives and go into the
/// log header (`mount`, `vehicle`).
struct PreDriveChecklist: Equatable, Sendable {
    var mountConfirmed = false
    var orientationConfirmed = false
    var mountNote = ""
    var vehicleNote = ""

    var isComplete: Bool { mountConfirmed && orientationConfirmed }

    /// Header `mount`: the note, or a statement of what was confirmed.
    var mountForHeader: String {
        let note = mountNote.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? "rigid mount, fixed orientation (confirmed; no note)" : note
    }

    var vehicleForHeader: String {
        vehicleNote.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Persists the notes (not the confirmations) in `UserDefaults`.
@MainActor
struct ChecklistStore {
    static let mountKey = "checklist.mountNote"
    static let vehicleKey = "checklist.vehicleNote"

    var defaults: UserDefaults = .standard

    func load() -> PreDriveChecklist {
        PreDriveChecklist(
            mountNote: defaults.string(forKey: Self.mountKey) ?? "",
            vehicleNote: defaults.string(forKey: Self.vehicleKey) ?? ""
        )
    }

    func save(_ checklist: PreDriveChecklist) {
        defaults.set(checklist.mountNote, forKey: Self.mountKey)
        defaults.set(checklist.vehicleNote, forKey: Self.vehicleKey)
    }
}

/// Whether the Start button may fire, and if not, what to tell the user.
/// Pure: the checklist and the session's blocker go in.
enum StartGate: Equatable {
    case ready
    case checklistIncomplete
    /// The session refuses; carries its explanation.
    case blocked(StartBlockerNotice)

    static func evaluate(checklist: PreDriveChecklist, blocker: StartBlockerNotice?) -> StartGate {
        if let blocker { return .blocked(blocker) }
        return checklist.isComplete ? .ready : .checklistIncomplete
    }

    var allowsStart: Bool { self == .ready }
}

/// Why Start is refused, in words, and whether "record without OBD" is the
/// way out (PLAN §3.3: an explicit choice, never automatic).
struct StartBlockerNotice: Equatable, Sendable {
    var message: String
    var offersRecordWithoutOBD: Bool

    /// nil for `recordingInProgress`: the controls already show that.
    init?(_ blocker: RecordingStartBlocker?) {
        switch blocker {
        case nil, .recordingInProgress?:
            return nil
        case .lowDiskSpace(let available, let required)?:
            message = "Not enough free space: \(DisplayFormat.bytes(available)) free, "
                + "\(DisplayFormat.bytes(required)) needed. Delete old sessions first."
            offersRecordWithoutOBD = false
        case .obdNotReady?:
            message = "The OBD adapter is not polling. Connect it in Console, "
                + "or choose to record without OBD."
            offersRecordWithoutOBD = true
        }
    }
}

/// Text for a failed `start`.
enum StartErrorText {
    static func message(for error: any Error) -> String {
        if let blocker = error as? RecordingStartBlocker {
            switch blocker {
            case .recordingInProgress: return "A recording is already running."
            default: return StartBlockerNotice(blocker)?.message ?? "Cannot start."
            }
        }
        return "Could not start: \(error.localizedDescription)"
    }
}
