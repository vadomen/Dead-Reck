import DriveLoggerCore
import SwiftUI

/// Layout E (UX-32): the 52 pt destination bar at the very bottom of the map,
/// just above the OSM credit band. While a route is active the same bar is the
/// next-manoeuvre bar. Nothing here appears on its own while the car moves:
/// the idle bar is always there, everything else follows a tap.
enum RouteBarLayout {
    /// The idle destination field.
    static let fieldHeight: Double = 52
    static let cornerRadius: Double = 16
    static let minTapTarget = MapLayout.minTapTarget
    /// The surface's left and right padding, shared by every bar.
    static let horizontalPadding: Double = 14
    /// Above and below the content of the guidance bar, and so of the away and
    /// arrived bars too (P52B-QA-2).
    static let verticalPadding: Double = 6

    /// The room for a card's scrolling part under `maxHeight` (the bar's cap,
    /// including its gap above the credit band): what is left after the
    /// surface's own padding (`chrome`), the pinned actions and the gap between.
    static func scrollRoom(maxHeight: Double?, pinnedHeight: Double, spacing: Double, chrome: Double) -> Double? {
        guard let maxHeight, maxHeight.isFinite else { return nil }
        let surface = maxHeight - MapLayout.aboveCreditGap
        // No floor: at the largest type the pinned actions take it all, and the rail must still clear the compass.
        return max(0, surface - chrome - pinnedHeight - spacing)
    }
}

/// A card whose information part (`info`) scrolls when the card would pass its
/// cap (R92.1-1); `pinned` sits below it and never scrolls. The place card pins
/// the failure message with Retry and the actions (`PlaceCardRow.pinned`), the
/// alternatives card pins Cancel and Start. The card hugs its content: `info` is
/// as high as it needs, and only an `info` taller than the room left under the
/// cap becomes a `ScrollView` of exactly that room (a ScrollView or ViewThatFits
/// would take all the height offered and stretch the card to the cap).
struct ScrollCard<Info: View, Pinned: View>: View {
    var maxHeight: Double?
    var spacing: Double
    /// The vertical padding the caller puts around the card.
    var chrome: Double
    @ViewBuilder var info: Info
    @ViewBuilder var pinned: Pinned
    @State private var pinnedHeight = 0.0
    /// `info`'s own height, measured on a hidden copy; 0 until measured (shown plain).
    @State private var infoHeight = 0.0

    var body: some View {
        let room = RouteBarLayout.scrollRoom(maxHeight: maxHeight, pinnedHeight: pinnedHeight, spacing: spacing, chrome: chrome)
        VStack(alignment: .leading, spacing: spacing) {
            Group {
                if let room, infoHeight > room {
                    ScrollView { info }.scrollIndicators(.visible).frame(height: room)
                } else {
                    info
                }
            }
            .background {
                info.fixedSize(horizontal: false, vertical: true).hidden()
                    .onGeometryChange(for: Double.self, of: { Double($0.size.height) }) { infoHeight = $0 }
            }
            // Its own height, never squeezed by the cap: the scrolling part takes what is left.
            pinned.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Double.self, of: { Double($0.size.height) }) { pinnedHeight = $0 }
        }
    }
}

struct RouteBottomBar: View {
    var flow: RouteFlowModel
    /// The most this bar may be high, gap included (`MapBottomLayout.maxRouteBarHeight`); nil: no cap.
    var maxHeight: Double?
    @State private var confirmsEnd = false

    init(flow: RouteFlowModel, maxHeight: Double? = nil) {
        self.flow = flow
        self.maxHeight = maxHeight
    }

    var body: some View {
        Group {
            switch flow.phase {
            case .idle, .search: DestinationField(onTap: { flow.openSearch() })
            case .placeCard: barSurface { PlaceCard(flow: flow, maxHeight: maxHeight) }
            case .requesting: RequestingBar(onCancel: { flow.dismiss() })
            case .alternatives: AlternativesCard(flow: flow, maxHeight: maxHeight)
            case .guiding: GuidanceBar(flow: flow, onEnd: { confirmsEnd = true })
            case .arrived: ArrivedBar(place: flow.arrivedPlace, onDone: { flow.acknowledgeArrival() })
            }
        }
        .padding(.horizontal, MapLayout.edgeInset)
        .padding(.bottom, MapLayout.aboveCreditGap)
        // Like the other map cards: wraps in full, never grows past AX2.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .confirmationDialog("End this route?", isPresented: $confirmsEnd, titleVisibility: .visible) {
            Button("Cancel route", role: .destructive) { flow.cancel() }
            Button("Keep route", role: .cancel) {}
        }
    }
}

@MainActor private func barSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(.horizontal, RouteBarLayout.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudSurface(RoundedRectangle(cornerRadius: RouteBarLayout.cornerRadius))
}

/// The idle bar: one tap opens the search.
struct DestinationField: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            barSurface {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .semibold))
                    Text("Where to?").font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: RouteBarLayout.fieldHeight)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Where to?"))
        .accessibilityAddTraits(.isSearchField)
    }
}

struct RequestingBar: View {
    var onCancel: () -> Void

    var body: some View {
        barSurface {
            HStack(spacing: 12) {
                ProgressView()
                Text("Finding routes…").font(.headline)
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .font(.headline)
                    .frame(minWidth: RouteBarLayout.minTapTarget, minHeight: RouteBarLayout.fieldHeight)
            }
            .frame(minHeight: RouteBarLayout.fieldHeight)
        }
    }
}

/// Up to three alternatives with distance and time, the chosen one emphasised,
/// and Start. The set is the one that was requested; nothing here asks again.
struct AlternativesCard: View {
    var flow: RouteFlowModel
    var maxHeight: Double?

    var body: some View {
        barSurface {
            ScrollCard(maxHeight: maxHeight, spacing: 6, chrome: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(flow.alternatives.enumerated()), id: \.offset) { index, route in
                        row(index: index, route: route)
                    }
                }
            } pinned: {
                HStack(spacing: 12) {
                    Button(flow.isRebuild && flow.active != nil ? String(localized: "Keep current route") : String(localized: "Cancel")) { flow.dismiss() }
                        .font(.headline)
                        .frame(minHeight: 52)
                    Spacer(minLength: 0)
                    Button { flow.start() } label: {
                        Text("Start")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(HUDColors.onAccent)
                            .padding(.horizontal, 36)
                            .frame(minHeight: 52)
                            .background(HUDColors.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func row(index: Int, route: Route) -> some View {
        let chosen = index == flow.chosenIndex
        return Button { flow.chooseAlternative(index) } label: {
            HStack(spacing: 10) {
                Capsule()
                    .fill(Color.violetLine(chosen: chosen))
                    .frame(width: chosen ? 8 : 5, height: 30)
                Text(RouteFormat.summary(route))
                    .font(chosen ? .title3.weight(.bold) : .body)
                    .foregroundStyle(chosen ? HUDColors.text : HUDColors.muted)
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(HUDColors.accentOnCard) }
            }
            .frame(minHeight: RouteBarLayout.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Route \(index + 1) of \(flow.alternatives.count), \(RouteFormat.summary(route))"))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private extension Color {
    /// The row swatch: the chosen route's line colour (the light-scheme one reads on both cards).
    static func violetLine(chosen: Bool) -> Color {
        RouteColors.color(RouteColors.line(dark: false, chosen: chosen))
    }
}

/// The next-manoeuvre bar: glyph, distance, instruction; second line the
/// remaining distance and time. Uncertain position: says so instead of a
/// distance. Far from the route: says so and offers Rebuild.
struct GuidanceBar: View {
    var flow: RouteFlowModel
    var onEnd: () -> Void

    var body: some View {
        let guidance = flow.guidance
        barSurface {
            HStack(alignment: .top, spacing: 12) {
                if let step = guidance?.nextStep {
                    Image(systemName: RouteFormat.symbol(step.maneuver))
                        .font(.system(size: 34, weight: .bold))
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(RouteFormat.name(step.maneuver))
                }
                VStack(alignment: .leading, spacing: 2) {
                    primary(guidance)
                    instruction(guidance)
                    secondary(guidance)
                    if guidance?.status == .awayFromRoute {
                        Button("Rebuild") { flow.rebuild() }
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .frame(minHeight: RouteBarLayout.minTapTarget)
                            .background(HUDColors.accent, in: Capsule())
                            .foregroundStyle(HUDColors.onAccent)
                            .padding(.top, 4)
                            .padding(.bottom, RouteBarLayout.verticalPadding)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onEnd) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(HUDColors.muted)
                        .frame(width: RouteBarLayout.minTapTarget, height: RouteBarLayout.minTapTarget)
                }
                .accessibilityLabel(Text("End route"))
            }
            .frame(minHeight: RouteBarLayout.fieldHeight, alignment: .top)
            .padding(.vertical, RouteBarLayout.verticalPadding)
        }
    }

    @ViewBuilder
    private func primary(_ guidance: RouteGuidance?) -> some View {
        switch guidance?.status {
        case .onRoute:
            if let next = guidance?.next {
                Text(RouteFormat.distance(next.distanceToM))
                    .font(.system(size: 32, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        case .uncertain:
            Label("Position uncertain", systemImage: "location.magnifyingglass")
                .font(.title3.weight(.bold))
                .foregroundStyle(HUDColors.warn)
        case .awayFromRoute:
            Label("Away from the route", systemImage: "arrow.triangle.branch")
                .font(.title3.weight(.bold))
                .foregroundStyle(HUDColors.warn)
        case nil:
            Text("Route started").font(.title3.weight(.bold))
        }
    }

    /// The provider's instruction: under the distance while on the route, muted
    /// while the position is uncertain (the last one known).
    @ViewBuilder
    private func instruction(_ guidance: RouteGuidance?) -> some View {
        if let step = guidance?.nextStep, guidance?.status != .awayFromRoute {
            Text(RouteFormat.instruction(step))
                .font(guidance?.status == .onRoute ? .headline : .subheadline)
                .foregroundStyle(guidance?.status == .onRoute ? HUDColors.text : HUDColors.muted)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func secondary(_ guidance: RouteGuidance?) -> some View {
        if flow.rebuildFailure != nil {
            Text("Could not rebuild. The current route stays.").font(.subheadline).foregroundStyle(HUDColors.warn)
        } else if let remaining = guidance?.remainingM, let time = guidance?.remainingTimeS {
            Text(RouteFormat.remaining(distanceM: remaining, timeS: time)).font(.subheadline).foregroundStyle(HUDColors.muted)
        }
    }
}

struct ArrivedBar: View {
    var place: RoutePlace?
    var onDone: () -> Void

    var body: some View {
        barSurface {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered").font(.system(size: 30, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arrived").font(.title2.weight(.bold))
                    if let place { Text(place.name).font(.subheadline).foregroundStyle(HUDColors.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Button("Done", action: onDone)
                    .font(.headline)
                    .frame(minWidth: RouteBarLayout.minTapTarget, minHeight: RouteBarLayout.fieldHeight)
            }
            .frame(minHeight: RouteBarLayout.fieldHeight)
            .padding(.vertical, RouteBarLayout.verticalPadding)
        }
        // Closes itself: nothing stays on the map once the trip is over.
        .task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { onDone() }
        }
    }
}
