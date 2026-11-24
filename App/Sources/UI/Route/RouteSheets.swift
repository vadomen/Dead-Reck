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
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchPasteButton { text = $0 }
                    savedRows
                } else {
                    CoordinateInputRow(flow: flow)
                    resultRows
                }
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
                if failure != .nothingFound, failure != .linkNoPoint {
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
enum PlaceCardRow: Equatable, CaseIterable {
    case header, originNote, failure, actions

    /// The rows that scroll past the bar's cap (R92.1-1): what the card says about the place (title, address, distance).
    static let scrolling: [PlaceCardRow] = [.header]
    /// The rows that never scroll, top to bottom: the origin note (P52C-QA-1: why Route is grey, always
    /// visible, directly above the buttons it explains), the failure message with Retry (R93.1-2: a tap on
    /// Route that fails is always answered on screen), then the actions. They keep their natural height
    /// (and `pinnedTypeLimit`), so the header's room, at least Close's 44 pt, is what scrolls.
    static let pinned: [PlaceCardRow] = [.originNote, .failure, .actions]
    /// The largest Dynamic Type size the pinned rows scale to: the default. Measured on the SE with the uk strings
    /// (the longest, uncertain + offline): at xxLarge the header's room is 32 pt, Close (44 pt) would cover the note,
    /// and from accessibility-medium up (xxxLarge too) the pinned part passes the cap on its own. The header scales.
    static let pinnedTypeLimit = DynamicTypeSize.large
}

/// Tests only (P52C-QA-1): receives the UIView behind the origin note ("note") and the Close button ("close"), so a test can read where the
/// note really is and whether a scroll view clips it. Nil, and a clear background, in the app.
private struct OriginNoteProbeKey: EnvironmentKey { static let defaultValue: (@MainActor (String, UIView) -> Void)? = nil }
extension EnvironmentValues {
    var originNoteProbe: (@MainActor (String, UIView) -> Void)? {
        get { self[OriginNoteProbeKey.self] }
        set { self[OriginNoteProbeKey.self] = newValue }
    }
}

private struct OriginNoteProbe: UIViewRepresentable {
    var name = "note"
    @Environment(\.originNoteProbe) private var probe
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { probe?(name, view) }
}

struct PlaceCard: View {
    var flow: RouteFlowModel
    /// The bar's cap (`RouteBottomBar.maxHeight`): only `PlaceCardRow.scrolling` (the header) scrolls past it; `pinned` stays.
    var maxHeight: Double?

    var body: some View {
        if let place = flow.place {
            ScrollCard(maxHeight: maxHeight, spacing: 10, chrome: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(PlaceCardRow.scrolling, id: \.self) { row($0, place: place) }
                }
            } pinned: {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(PlaceCardRow.pinned, id: \.self) { row($0, place: place) }
                }
                // The pinned rows never grow past what the cap holds (P52C-QA-1): at the largest sizes the
                // bar would pass the cap and the rail would cover the compass. The header scrolls and still scales.
                .dynamicTypeSize(...PlaceCardRow.pinnedTypeLimit)
            }
            // Close is not text: it stays put at the top trailing corner, outside the scrolling header.
            .overlay(alignment: .topTrailing) {
                Button { flow.dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                        .frame(width: RouteBarLayout.minTapTarget, height: RouteBarLayout.minTapTarget)
                }
                .accessibilityLabel(Text("Close"))
                .background { OriginNoteProbe(name: "close") }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func row(_ row: PlaceCardRow, place: RoutePlace) -> some View {
        switch row {
        case .header:
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
            }
            .padding(.trailing, RouteBarLayout.minTapTarget)
            .frame(maxWidth: .infinity, minHeight: RouteBarLayout.minTapTarget, alignment: .topLeading)
        case .originNote:
            originNote.background { OriginNoteProbe() }
        case .failure:
            if let failure = flow.failure {
                HStack {
                    Text(RouteFormat.message(failure)).font(.headline).foregroundStyle(HUDColors.warn)
                    Spacer(minLength: 0)
                    if failure != .nothingFound { Button("Retry") { flow.retry() }.font(.headline) }
                }
            }
        case .actions:
            actions(place: place)
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
