import SwiftUI

/// Wording of the first-launch maps step (UX-8 (1)). Pure functions, so the
/// button text per network state is testable.
enum FirstLaunchMapsText {
    static let title = "Road maps"
    static let why = "Maps help navigation when GPS is poor. Nothing downloads until you tap the button."
    static let allowLocation = "Allow location to suggest your region's map. It stays on the phone."
    static let lookingForRegion = "Looking for your region…"
    static let later = "Download maps later"
    static let laterNote = "Later, everything is in Settings → Maps."
    static let useCellular = "Use cellular data"
    static let loading = "Loading the list of maps…"
    static let noListTitle = "The list of maps is not available"
    static let noListDetail = "There is no connection. Navigation works without maps; you can download them later in Settings → Maps."
    static let nearby = "Nearby"
    static let installed = "Installed"
    static let offlineNote = "No connection. The download starts when you are online."
    static let cellularNote = "You are on cellular data. The download waits for Wi-Fi."

    static func maps(_ count: Int) -> String { count == 1 ? "1 map" : "\(count) maps" }

    /// "Download 2 maps · 61.0 MB", with " on Wi-Fi" when it will wait for Wi-Fi.
    static func confirmTitle(count: Int, bytes: Int64, network: FirstLaunchMapsModel.Network) -> String {
        let base = "Download \(maps(count)) · \(MapsText.size(bytes))"
        return network == .waitsForWiFi ? base + " on Wi-Fi" : base
    }

    /// The line under the button for a network that will not start at once.
    static func networkNote(_ network: FirstLaunchMapsModel.Network) -> String? {
        switch network {
        case .ready: nil
        case .waitsForWiFi: cellularNote
        case .offline: offlineNote
        }
    }

    /// Row caption: "Installed", "Nearby", or nil.
    static func caption(_ row: FirstLaunchMapsModel.Row) -> String? {
        if row.isInstalled { return installed }
        return row.role == .neighbour ? nearby : nil
    }
}

/// The step, wired to its model. Shown after the UX-1 checklist.
struct FirstLaunchMapsView: View {
    var model: FirstLaunchMapsModel

    var body: some View {
        FirstLaunchMapsContent(
            listState: model.listState, rows: model.rows, network: model.network, fixState: model.fixState,
            asksLocation: model.asksLocation, selectedCount: model.selectedCount, selectedBytes: model.selectedBytes, canConfirm: model.canConfirm,
            onToggle: { model.toggle($0) }, onConfirm: { Task { await model.confirm() } },
            onUseCellular: { Task { await model.useCellular() } }, onLater: { model.later() }
        )
        .task { await model.run() }
    }
}

/// Plain values, for previews and screenshots.
struct FirstLaunchMapsContent: View {
    var listState: FirstLaunchMapsModel.ListState
    var rows: [FirstLaunchMapsModel.Row]
    var network: FirstLaunchMapsModel.Network
    var fixState: FirstLaunchMapsModel.FixState
    /// The permission prompt is coming or showing.
    var asksLocation = false
    var selectedCount: Int
    var selectedBytes: Int64
    var canConfirm: Bool
    var onToggle: (String) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    var onUseCellular: () -> Void = {}
    var onLater: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(FirstLaunchMapsText.title).font(.largeTitle.bold())
                Text(FirstLaunchMapsText.why).font(.title3).foregroundStyle(.secondary)
                if asksLocation {
                    Label(FirstLaunchMapsText.allowLocation, systemImage: "location")
                        .font(.subheadline.weight(.semibold))
                } else if fixState == .waiting, listState != .noList {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(FirstLaunchMapsText.lookingForRegion).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            middle
            footer
        }
    }

    @ViewBuilder
    private var middle: some View {
        switch listState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(FirstLaunchMapsText.loading).font(.title3).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noList:
            VStack(alignment: .leading, spacing: 8) {
                Label(FirstLaunchMapsText.noListTitle, systemImage: "wifi.slash")
                    .font(.title3.weight(.semibold)).foregroundStyle(Tone.caution.color)
                Text(FirstLaunchMapsText.noListDetail).font(.body).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .ready:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        FirstLaunchMapsRow(row: row) { onToggle(row.id) }
                        Divider().padding(.leading, 72)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if listState == .ready {
                Button(action: onConfirm) {
                    Text(FirstLaunchMapsText.confirmTitle(count: selectedCount, bytes: selectedBytes, network: network))
                        .font(.title2.bold()).multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7).frame(maxWidth: .infinity, minHeight: 64)
                }
                .prominentButton()
                .disabled(!canConfirm)
                if let note = FirstLaunchMapsText.networkNote(network) {
                    Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if network == .waitsForWiFi {
                    Button(action: onUseCellular) {
                        Text(FirstLaunchMapsText.useCellular).font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Button(action: onLater) {
                Text(FirstLaunchMapsText.later).font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            Text(FirstLaunchMapsText.laterNote).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(.bar)
    }
}

/// One pack: check mark, title, size; "Nearby" or "Installed" under the title.
struct FirstLaunchMapsRow: View {
    let row: FirstLaunchMapsModel.Row
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(row.isInstalled ? Color.secondary : row.isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    if let caption = FirstLaunchMapsText.caption(row) {
                        Text(caption).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(MapsText.size(row.sizeBytes)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.isInstalled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(MapsText.size(row.sizeBytes))" + (FirstLaunchMapsText.caption(row).map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var icon: String {
        if row.isInstalled { return "checkmark.seal.fill" }
        return row.isSelected ? "checkmark.circle.fill" : "circle"
    }
}

// MARK: - Previews (synthetic)

enum FirstLaunchMapsPreviewData {
    typealias Row = FirstLaunchMapsModel.Row

    static let rows: [Row] = [
        Row(id: "zz-00", title: "National roads", sizeBytes: 41_000_000, role: .national, isSelected: true, isInstalled: false),
        Row(id: "zz-01", title: "Region A", sizeBytes: 35_000_000, role: .region, isSelected: true, isInstalled: false),
        Row(id: "zz-02", title: "Region B", sizeBytes: 28_000_000, role: .neighbour, isSelected: false, isInstalled: false),
        Row(id: "zz-03", title: "Region C", sizeBytes: 47_000_000, role: .neighbour, isSelected: false, isInstalled: false),
        Row(id: "zz-04", title: "Region D", sizeBytes: 22_000_000, role: .other, isSelected: false, isInstalled: false),
        Row(id: "zz-05", title: "Region E", sizeBytes: 31_000_000, role: .other, isSelected: false, isInstalled: true),
        Row(id: "zz-06", title: "Region F", sizeBytes: 26_000_000, role: .other, isSelected: false, isInstalled: false),
    ]
}

#Preview("Maps step, region found") {
    FirstLaunchMapsContent(listState: .ready, rows: FirstLaunchMapsPreviewData.rows, network: .ready,
                           fixState: .found(region: "zz-01"), selectedCount: 2, selectedBytes: 76_000_000, canConfirm: true)
}

#Preview("Maps step, asking location") {
    FirstLaunchMapsContent(listState: .ready, rows: FirstLaunchMapsPreviewData.rows, network: .ready,
                           fixState: .waiting, asksLocation: true, selectedCount: 1, selectedBytes: 41_000_000,
                           canConfirm: true)
}

#Preview("Maps step, cellular, looking, dark") {
    FirstLaunchMapsContent(listState: .ready, rows: FirstLaunchMapsPreviewData.rows, network: .waitsForWiFi,
                           fixState: .waiting, selectedCount: 2, selectedBytes: 76_000_000, canConfirm: true)
        .preferredColorScheme(.dark)
}

#Preview("Maps step, nothing selected") {
    FirstLaunchMapsContent(listState: .ready, rows: FirstLaunchMapsPreviewData.rows.map { var r = $0; r.isSelected = false; return r },
                           network: .offline, fixState: .none, selectedCount: 0, selectedBytes: 0, canConfirm: false)
}

#Preview("Maps step, no list") {
    FirstLaunchMapsContent(listState: .noList, rows: [], network: .offline, fixState: .none,
                           selectedCount: 0, selectedBytes: 0, canConfirm: false)
}

#Preview("Maps step, loading") {
    FirstLaunchMapsContent(listState: .loading, rows: [], network: .ready, fixState: .waiting,
                           selectedCount: 0, selectedBytes: 0, canConfirm: false)
}
