import CoreGraphics

/// The map's bottom edge as one column (UX-33): the credit line owns the lowest
/// `MapLayout.attributionBand`, and everything else (the bottom-left stack, the
/// rail) sits above it. Pure, so a test can check every combination without a
/// view; `MapScreen.bottomArea` builds the same column (credit row last, the
/// rest above it), so the order below is the order on screen.
enum MapBottomLayout {
    /// The credit line's own height inside its band (the band keeps 4 pt below it).
    static let creditHeight: Double = 18

    struct Frames: Equatable {
        /// The OSM credit; nil when no pack is in use.
        var credit: CGRect?
        /// The bottom-left stack, in the order given (top to bottom).
        var items: [(item: MapBottomItem, frame: CGRect)]
        var rail: CGRect

        static func == (lhs: Frames, rhs: Frames) -> Bool {
            lhs.credit == rhs.credit && lhs.rail == rhs.rail
                && lhs.items.map(\.item) == rhs.items.map(\.item) && lhs.items.map(\.frame) == rhs.items.map(\.frame)
        }
    }

    /// Frames inside `container` (the map's size inside the safe area).
    /// - `items`: the stack top to bottom with each element's size (as
    ///   `MapBottomZone.items` orders them); the stack is as wide as the room
    ///   left of the rail at most.
    /// - `creditWidth`: nil when no pack is in use (nothing drawn, band kept).
    /// Items and the rail grow upward from `MapLayout.bottomInset()`; the
    /// credit is pinned to the bottom of the container. A tall stack can leave
    /// the top of the container, never reach down into the credit.
    static func frames(
        container: CGSize, items: [(item: MapBottomItem, size: CGSize)], railSize: CGSize, creditWidth: Double?
    ) -> Frames {
        let width = Double(container.width)
        let height = Double(container.height)
        let stackBottom = height - MapLayout.bottomInset()
        let stackWidth = max(0, width - MapLayout.edgeInset - MapLayout.railReserved)
        var y = stackBottom
        var placed: [(item: MapBottomItem, frame: CGRect)] = []
        for entry in items.reversed() {
            let w = min(Double(entry.size.width), stackWidth)
            let h = Double(entry.size.height)
            y -= h
            placed.append((entry.item, CGRect(x: MapLayout.edgeInset, y: y, width: w, height: h)))
            y -= MapBottomLayout.itemGap
        }
        let railW = Double(railSize.width)
        let railH = Double(railSize.height)
        let rail = CGRect(x: width - MapLayout.edgeInset - railW, y: stackBottom - railH, width: railW, height: railH)
        let credit = creditWidth.map {
            CGRect(x: width - MapLayout.edgeInset - $0, y: height - MapLayout.attributionBand, width: $0, height: creditHeight)
        }
        return Frames(credit: credit, items: placed.reversed(), rail: rail)
    }

    /// Space between stacked items.
    static let itemGap: Double = 8
}
