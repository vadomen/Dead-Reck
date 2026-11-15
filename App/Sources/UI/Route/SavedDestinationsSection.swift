import DriveLoggerCore
import SwiftUI

/// Settings → saved destinations: Home, Work, the recents; per-item delete and
/// "Clear recent destinations" (with a confirmation). On the device only.
struct SavedDestinationsSection: View {
    var store: SavedDestinationsStore
    @State private var confirmsClear = false

    var body: some View {
        Section {
            if store.isEmpty {
                Text("No saved destinations yet").foregroundStyle(.secondary).frame(minHeight: 44)
            }
            if let home = store.home { row(home, title: String(localized: "Home"), symbol: "house.fill") { store.setHome(nil) } }
            if let work = store.work { row(work, title: String(localized: "Work"), symbol: "briefcase.fill") { store.setWork(nil) } }
            ForEach(store.recents, id: \.dedupKey) { place in
                row(place, title: place.name, symbol: "clock") { store.removeRecent(place) }
            }
            if !store.recents.isEmpty {
                Button("Clear recent destinations", role: .destructive) { confirmsClear = true }
                    .frame(minHeight: 44)
            }
        } header: {
            Text("Saved destinations")
        } footer: {
            Text("Kept on this iPhone only, never sent to us.")
        }
        .confirmationDialog("Clear recent destinations?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear recent destinations", role: .destructive) { store.clearRecents() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ place: RoutePlace, title: String, symbol: String, remove: @escaping () -> Void) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !place.addressLine.isEmpty { Text(place.addressLine).font(.footnote).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .frame(minHeight: 44, alignment: .leading)
        .swipeActions {
            Button("Delete", role: .destructive, action: remove)
        }
    }
}

/// Settings → Diagnostics: what `RouteEdgeMatcher` said about the active route
/// (prompt 53 will use it). Shown with the developer rows only.
struct RouteDiagnosticsSection: View {
    var flow: RouteFlowModel

    var body: some View {
        Section("Route") {
            LabeledContent("Route roads", value: text)
        }
    }

    private var text: String {
        guard let active = flow.active else { return String(localized: "No active route") }
        guard active.edgeMatchDone else { return String(localized: "Matching…") }
        guard let match = active.edgeMatch else { return String(localized: "No road pack covers the route") }
        let coverage = match.coverage.formatted(.percent.precision(.fractionLength(0)))
        return match.isWeak ? String(localized: "\(coverage) on known roads (weak)") : String(localized: "\(coverage) on known roads")
    }
}

private struct SavedDestinationsKey: EnvironmentKey { static let defaultValue: SavedDestinationsStore? = nil }
private struct RouteFlowKey: EnvironmentKey { static let defaultValue: RouteFlowModel? = nil }

extension EnvironmentValues {
    var savedDestinations: SavedDestinationsStore? {
        get { self[SavedDestinationsKey.self] }
        set { self[SavedDestinationsKey.self] = newValue }
    }

    var routeFlow: RouteFlowModel? {
        get { self[RouteFlowKey.self] }
        set { self[RouteFlowKey.self] = newValue }
    }
}
