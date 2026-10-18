import Foundation
import Observation
import SwiftUI

/// Pure text and rules for Settings → Maps.
enum MapsText {
    static let empty = "No road maps installed"
    static let emptyDetail = "Road maps are optional. Navigation works without them."
    static let restartNote = "Removal takes effect after the app restarts."

    /// "Coverage area" (the pack has a coverage polygon), "Bounding box only"
    /// (it has none: the map matcher falls back to the box) or "Coverage unknown"
    /// (not verified, so not read).
    static func coverage(_ pack: RoadPackLibrary.PackStatus) -> String {
        switch pack.hasCoverage {
        case true?: "Coverage area"
        case false?: "Bounding box only"
        case nil: "Coverage unknown"
        }
    }

    static func size(_ bytes: Int64?) -> String {
        bytes.map { String(format: "%.1f MB", Double($0) / 1_000_000) } ?? "-- MB"
    }

    /// "OSM 2026-10-01", or "OSM date unknown".
    static func osmDate(_ pack: RoadPackLibrary.PackStatus) -> String {
        guard let ts = pack.osmTimestamp, ts > 0 else { return "OSM date unknown" }
        return "OSM " + Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.iso8601.year().month().day())
    }

    /// First 8 hex digits of the content hash.
    static func hash(_ pack: RoadPackLibrary.PackStatus) -> String {
        pack.hashPrefix.map { String($0.prefix(8)) } ?? "no hash"
    }

    static func totalStorage(_ bytes: Int64?) -> String { "Storage used: " + size(bytes) }

    /// The credit sits under the list whenever any pack is listed.
    static func attributionVisible(packs: [RoadPackLibrary.PackStatus]) -> Bool { !packs.isEmpty }

    /// Remove is offered for a stored pack not already marked for removal.
    static func canRemove(_ pack: RoadPackLibrary.PackStatus) -> Bool {
        pack.packName != nil && !pack.pendingRemoval && !pack.inInbox
    }

    static func confirmationTitle(_ pack: RoadPackLibrary.PackStatus) -> String {
        "Remove \(pack.displayName)?"
    }

    static func confirmationMessage(_ pack: RoadPackLibrary.PackStatus) -> String {
        "Frees \(size(pack.sizeBytes)). Recordings are not affected."
    }

    /// The notice after Remove, nil when nothing needs saying.
    static func notice(_ outcome: RoadPackLibrary.RemoveOutcome, packName: String) -> String? {
        switch outcome {
        case .deleted: nil
        case .removalPending: "\(packName): " + restartNote
        case .notInstalled: "\(packName) is not installed."
        case .failed(let reason): "Could not remove \(packName): \(reason)"
        }
    }

    /// Green when usable, red when refused, orange while removal is pending.
    static func tone(_ pack: RoadPackLibrary.PackStatus) -> Tone {
        if pack.pendingRemoval { return .caution }
        return pack.verified ? .good : .bad
    }
}

/// Reads and changes the installed packs for Settings → Maps.
@MainActor
@Observable
final class MapsModel {
    private(set) var status = RoadPackLibrary.Status.empty
    /// The result of the latest Remove that needs saying.
    private(set) var notice: String?
    @ObservationIgnored private let library: RoadPackLibrary?

    init(library: RoadPackLibrary) { self.library = library }

    /// Previews and tests: fixed values.
    init(status: RoadPackLibrary.Status, notice: String? = nil) {
        self.status = status
        self.notice = notice
        library = nil
    }

    func refresh() async {
        guard let library else { return }
        let next = await library.status()
        if next != status { status = next }
    }

    /// While Maps is visible: rescan once, then refresh every 2 s.
    func run() async {
        if let library { Task(priority: .utility) { await library.rescan() } }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func remove(_ pack: RoadPackLibrary.PackStatus) async {
        guard let library, MapsText.canRemove(pack), let name = pack.packName else { return }
        let outcome = await library.remove(name: name)
        notice = MapsText.notice(outcome, packName: pack.displayName)
        await refresh()
    }

    func dismissNotice() { notice = nil }
}

/// Settings → Maps: the model wired to the plain-values content.
struct MapsScreen: View {
    var model: MapsModel
    @State private var confirming: RoadPackLibrary.PackStatus?

    var body: some View {
        MapsContent(
            packs: model.status.installedPacks, storeBytes: model.status.storeBytes, notice: model.notice,
            onRemove: { confirming = $0 }, onDismissNotice: { model.dismissNotice() }
        )
        .confirmationDialog(
            confirming.map(MapsText.confirmationTitle) ?? "", isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible, presenting: confirming
        ) { pack in
            Button("Remove", role: .destructive) { Task { await model.remove(pack) } }
            Button("Cancel", role: .cancel) {}
        } message: { pack in
            Text(MapsText.confirmationMessage(pack))
        }
        .task { await model.run() }
    }
}

/// Plain-values presentation, for previews.
struct MapsContent: View {
    let packs: [RoadPackLibrary.PackStatus]
    let storeBytes: Int64?
    var notice: String?
    var onRemove: (RoadPackLibrary.PackStatus) -> Void = { _ in }
    var onDismissNotice: () -> Void = {}

    var body: some View {
        List {
            if let notice {
                Section {
                    HStack {
                        Text(notice).font(.callout)
                        Spacer(minLength: 8)
                        Button("OK", action: onDismissNotice).buttonStyle(.bordered)
                    }
                }
            }
            if packs.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MapsText.empty).font(.title3.weight(.semibold))
                        Text(MapsText.emptyDetail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(packs) { pack in row(pack) }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MapsText.totalStorage(storeBytes))
                        if MapsText.attributionVisible(packs: packs) {
                            Text(RoadsDiagnosticsText.attribution)
                        }
                    }
                }
            }
        }
    }

    private func row(_ pack: RoadPackLibrary.PackStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pack.displayName).font(.title3.weight(.semibold))
            Text(RoadsDiagnosticsText.state(pack))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MapsText.tone(pack).color)
            Text([MapsText.size(pack.sizeBytes), MapsText.osmDate(pack)].joined(separator: " · "))
                .font(.subheadline)
            Text([MapsText.coverage(pack), MapsText.hash(pack)].joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if MapsText.canRemove(pack) {
                Button(role: .destructive) { onRemove(pack) } label: {
                    Label("Remove", systemImage: "trash").frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Previews (synthetic names)

extension RoadPackLibrary.PackStatus {
    static func preview(
        _ name: String, bytes: Int64 = 48_000_000, osm: Int64 = 1_760_000_000, hash: String = "a1b2c3d4",
        coverage: Bool? = true, refusal: String? = nil, pending: Bool = false
    ) -> Self {
        var pack = RoadPackLibrary.PackStatus(
            name: "\(name)-\(hash)00000000.roadpack", verified: refusal == nil && !pending,
            refusal: pending ? RoadPackLibrary.removalPendingText : refusal, sizeBytes: bytes,
            osmTimestamp: osm, hashPrefix: hash, cacheHit: true, verifySeconds: nil)
        pack.packName = name
        pack.hasCoverage = coverage
        pack.pendingRemoval = pending
        return pack
    }
}

#Preview("Maps, empty") {
    NavigationStack { MapsContent(packs: [], storeBytes: 0).navigationTitle("Maps") }
}

#Preview("Maps, two packs") {
    NavigationStack {
        MapsContent(
            packs: [.preview("national", bytes: 120_000_000, hash: "0f0e0d0c", coverage: false),
                    .preview("region-a", hash: "a1b2c3d4")],
            storeBytes: 168_000_000
        ).navigationTitle("Maps")
    }
}

#Preview("Maps, removal pending") {
    NavigationStack {
        MapsContent(
            packs: [.preview("national", coverage: false), .preview("region-a", pending: true),
                    .preview("region-b", coverage: nil, refusal: "truncated")],
            storeBytes: 150_000_000, notice: "region-a: " + MapsText.restartNote
        ).navigationTitle("Maps")
    }
}
