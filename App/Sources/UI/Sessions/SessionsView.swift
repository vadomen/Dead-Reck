import SwiftUI

struct SessionsScreen: View {
    @Bindable var model: SessionsViewModel

    var body: some View {
        SessionsContent(
            files: model.files,
            activeFile: model.isRecording ? model.activeFile : nil,
            errorMessage: model.errorMessage,
            pendingDelete: $model.pendingDelete,
            onDelete: { file in Task { await model.delete(file) } },
            onRefresh: { await model.refresh() }
        )
        .task { await model.refresh() }
        // A recording that just ended must show up without a pull-to-refresh.
        .onChange(of: model.isRecording) { _, isRecording in
            if !isRecording { Task { await model.refresh() } }
        }
    }
}

struct SessionsContent: View {
    let files: [RecordingFile]
    var activeFile: URL?
    var errorMessage: String?
    @Binding var pendingDelete: RecordingFile?
    var onDelete: (RecordingFile) -> Void = { _ in }
    var onRefresh: () async -> Void = {}

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(files) { file in
                    SessionRow(file: file, isActive: file.url == activeFile) {
                        pendingDelete = file
                    }
                }
            }
            .overlay {
                if files.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "tray", description: Text("Recordings appear here after you stop."))
                }
            }
            .refreshable { await onRefresh() }
            .navigationTitle("Sessions")
            .confirmationDialog(
                pendingDelete.map(SessionsText.confirmationTitle(for:)) ?? "Delete recording?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { file in
                Button("Delete", role: .destructive) { onDelete(file) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { file in
                Text("\(file.name) (\(DisplayFormat.bytes(file.sizeBytes))) will be permanently deleted. This cannot be undone.")
            }
        }
    }
}

struct SessionRow: View {
    let file: RecordingFile
    let isActive: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionsText.title(for: file)).font(.headline)
                Text(SessionsText.summary(for: file)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                if isActive {
                    Text("Recording now").font(.caption.weight(.bold)).foregroundStyle(.red)
                }
            }
            Spacer()
            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up").font(.title3).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(isActive)
            .accessibilityLabel("Export")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.title3).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(isActive)
            .accessibilityLabel("Delete")
        }
    }
}

// MARK: - Previews

extension RecordingFile {
    static func preview(_ name: String, size: Int, hoursAgo: Double, duration: TimeInterval?) -> RecordingFile {
        RecordingFile(
            url: URL(fileURLWithPath: "/tmp/\(name).jsonl.gz"),
            name: "\(name).jsonl.gz",
            sizeBytes: size,
            startedAt: Date(timeIntervalSinceNow: -hoursAgo * 3600),
            duration: duration
        )
    }
}

private struct SessionsPreviewHost: View {
    var files: [RecordingFile]
    var activeFile: URL?
    @State var pending: RecordingFile?

    var body: some View {
        SessionsContent(files: files, activeFile: activeFile, pendingDelete: $pending)
    }
}

#Preview("Sessions") {
    let files = [
        RecordingFile.preview("Drive_20261008-091500", size: 182_400_000, hoursAgo: 2, duration: 3 * 3600 + 125),
        .preview("Drive_20261007-181200", size: 42_100_000, hoursAgo: 20, duration: 1_240),
        .preview("Drive_20261006-080000", size: 900, hoursAgo: 40, duration: nil),
    ]
    SessionsPreviewHost(files: files, activeFile: files[0].url)
}

#Preview("Sessions, delete confirmation") {
    let files = [RecordingFile.preview("Drive_20261007-181200", size: 42_100_000, hoursAgo: 20, duration: 1_240)]
    SessionsPreviewHost(files: files, pending: files[0])
}

#Preview("Sessions, empty") {
    SessionsPreviewHost(files: [])
}
