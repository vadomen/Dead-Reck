import Foundation
import Observation

/// State and actions of the Sessions tab.
@MainActor
@Observable
final class SessionsViewModel {
    private(set) var files: [RecordingFile] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The file the confirmation dialog is asking about.
    var pendingDelete: RecordingFile?

    @ObservationIgnored private let session: RecordingSession
    @ObservationIgnored private let store: LogStore

    init(services: AppServices) {
        session = services.session
        store = services.store
    }

    /// The file being written right now; the list marks it and refuses to delete it.
    var activeFile: URL? { session.currentFile }

    var isRecording: Bool {
        switch session.state {
        case .calibrating, .recording, .stopping: true
        case .idle, .failed: false
        }
    }

    /// Lists off the main actor: `list()` reads each file's header and tail.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let store = store
        do {
            files = try await Task.detached { try store.list() }.value
            errorMessage = nil
        } catch {
            // No logs folder yet means no recordings.
            files = []
            let ns = error as NSError
            errorMessage = ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError
                ? nil : "Could not read recordings: \(error.localizedDescription)"
        }
    }

    func delete(_ file: RecordingFile) async {
        do {
            try await session.deleteRecording(file)
            errorMessage = nil
        } catch {
            errorMessage = SessionsText.deleteError(error)
        }
        pendingDelete = nil
        await refresh()
    }
}

/// Pure text for the sessions list.
enum SessionsText {
    static func deleteError(_ error: any Error) -> String {
        if let store = error as? LogStoreError {
            switch store {
            case .recordingInProgress: return "This recording is still running. Stop it first."
            case .notInStore: return "That file is not in the recordings folder."
            }
        }
        return "Could not delete: \(error.localizedDescription)"
    }

    static func title(for file: RecordingFile) -> String {
        guard let date = file.startedAt else { return file.name }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func summary(for file: RecordingFile) -> String {
        "\(DisplayFormat.duration(file.duration)) · \(DisplayFormat.bytes(file.sizeBytes))"
    }

    static func confirmationTitle(for file: RecordingFile) -> String {
        "Delete \(title(for: file))?"
    }
}
