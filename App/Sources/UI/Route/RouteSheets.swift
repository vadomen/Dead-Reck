import DriveLoggerCore
import SwiftUI

/// The search sheet: a full-height sheet, opened only by a tap, never by itself.
/// The place card is not a sheet: it sits in the map's bottom column like the
/// alternatives card (`RouteBottomBar`), so the right rail stays above it and its
/// height is its content's, with no detent to guess.
struct RouteSheets: ViewModifier {
    var flow: RouteFlowModel?

    private var isShown: Binding<Bool> {
        Binding(
            get: { flow.map { $0.phase == .search } ?? false },
            set: { shown in
                if !shown, let flow, flow.phase == .search { flow.dismiss() }
            })
    }

    func body(content: Content) -> some View {
        content.sheet(isPresented: isShown) {
            if let flow {
                DestinationSearchSheet(flow: flow)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

extension View {
    func routeSheets(_ flow: RouteFlowModel?) -> some View { modifier(RouteSheets(flow: flow)) }
}

// MARK: - Search

struct DestinationSearchSheet: View {
    var flow: RouteFlowModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if text.trimmingCharacters(in: .whitespaces).isEmpty { savedRows } else { resultRows }
            }
            .listStyle(.plain)
            .navigationTitle("Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { flow.dismiss() }
                        .frame(minWidth: RouteBarLayout.minTapTarget, minHeight: RouteBarLayout.minTapTarget)
                }
            }
            .safeAreaInset(edge: .top) { field }
        }
        .onChange(of: text) { _, new in flow.updateQuery(new) }
        .onAppear {
            text = flow.query
            focused = true
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Address or place", text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .font(.title3)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .frame(width: RouteBarLayout.minTapTarget, height: RouteBarLayout.minTapTarget)
                    .accessibilityLabel(Text("Clear text"))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: RouteBarLayout.fieldHeight)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: RouteBarLayout.cornerRadius))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var savedRows: some View {
        let store = flow.saved
        if let home = store.home { savedRow(home, title: String(localized: "Home"), symbol: "house.fill") }
        if let work = store.work { savedRow(work, title: String(localized: "Work"), symbol: "briefcase.fill") }
        if !store.recents.isEmpty {
            Section("Recent") {
                ForEach(store.recents, id: \.dedupKey) { place in
                    savedRow(place, title: place.name, symbol: "clock")
                }
            }
        }
    }

    private func savedRow(_ place: RoutePlace, title: String, symbol: String) -> some View {
        Button { flow.select(place) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if !place.addressLine.isEmpty { Text(place.addressLine).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: RouteBarLayout.fieldHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var resultRows: some View {
        switch flow.searchStatus {
        case .idle: EmptyView()
        case .loading:
            if flow.completions.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 60) }
            completionRows
        case .ready: completionRows
        case .failure(let failure):
            VStack(alignment: .leading, spacing: 10) {
                Text(RouteFormat.message(failure)).font(.headline)
                if failure != .nothingFound {
                    Button("Retry") { flow.retrySearch() }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: RouteBarLayout.fieldHeight)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var completionRows: some View {
        ForEach(flow.completions) { completion in
            Button { flow.select(completion) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title).font(.headline)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: RouteBarLayout.fieldHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Place card

/// The place card's content; `RouteBottomBar` puts it on the bar surface.
struct PlaceCard: View {
    var flow: RouteFlowModel

    var body: some View {
        if let place = flow.place {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).font(.title2.weight(.bold)).lineLimit(2)
                        if !place.addressLine.isEmpty {
                            Text(place.addressLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let distance = flow.distanceToPlaceM {
                            Text("Straight line, \(RouteFormat.distance(distance))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { flow.dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                            .frame(width: RouteBarLayout.minTapTarget, height: RouteBarLayout.minTapTarget)
                    }
                    .accessibilityLabel(Text("Close"))
                }
                originNote
                if let failure = flow.failure {
                    HStack {
                        Text(RouteFormat.message(failure)).font(.headline).foregroundStyle(HUDColors.warn)
                        Spacer(minLength: 0)
                        if failure != .nothingFound { Button("Retry") { flow.retry() }.font(.headline) }
                    }
                }
                actions(place: place)
            }
            .padding(.vertical, 10)
        }
    }

    /// What the origin rule says, as facts (nothing asks the driver to use the phone while driving).
    @ViewBuilder
    private var originNote: some View {
        switch flow.originChoice {
        case .estimate, .fix: EmptyView()
        case .uncertain(_, let pin):
            Label(pin == nil ? String(localized: "Your position is uncertain. A pin on the map sets it.") : String(localized: "The pin is your starting point."),
                  systemImage: pin == nil ? "location.magnifyingglass" : "mappin")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(pin == nil ? HUDColors.warn : .primary)
        case .needsPin(let pin):
            Label(pin == nil ? String(localized: "No reliable position. A pin on the map sets it.") : String(localized: "The pin is your starting point."),
                  systemImage: pin == nil ? "location.slash" : "mappin")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(pin == nil ? HUDColors.warn : .primary)
        }
    }

    private var routeEnabled: Bool { RouteOriginRule.resolve(flow.originChoice) != nil }

    private func actions(place: RoutePlace) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Menu {
                    Button("Save as Home") { flow.saved.setHome(place) }
                    Button("Save as Work") { flow.saved.setWork(place) }
                    Button("Keep in recents") { flow.saved.addRecent(place) }
                } label: {
                    Label("Pin", systemImage: "pin")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: RouteBarLayout.cornerRadius))
                }
                Button { flow.route() } label: {
                    Label(flow.isRebuild ? String(localized: "Rebuild") : String(localized: "Route"), systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.title3.weight(.bold))
                        // Disabled: a flat grey face with readable secondary text, not a faded blue one.
                        .foregroundStyle(routeEnabled ? HUDColors.onAccent : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(
                            routeEnabled ? AnyShapeStyle(HUDColors.accent) : AnyShapeStyle(Color(.tertiarySystemFill)),
                            in: RoundedRectangle(cornerRadius: RouteBarLayout.cornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(!routeEnabled)
            }
            if case .uncertain = flow.originChoice {
                Button("Route anyway") { flow.route(anyway: true) }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: RouteBarLayout.minTapTarget)
            }
        }
    }
}
