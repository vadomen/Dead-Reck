import CoreGraphics
import Testing
@testable import DriveLogger

/// UX-33: the OSM credit is never covered, whatever the bottom shows.
@Suite("Map bottom layout")
struct MapBottomLayoutTests {
    /// Container sizes inside the safe area: SE (3rd gen) and a Pro Max.
    private static let containers = [CGSize(width: 375, height: 667), CGSize(width: 440, height: 874 - 34 - 59)]
    /// Element heights at the default size and a tall AX3-like one.
    private static let heightScales: [Double] = [1, 2.2]
    private static let baseHeight: [MapBottomItem: Double] = [
        .offerCard: 130, .toast: 56, .statusLine: 56, .positionStatus: 44, .restoreStatus: 44,
        .roadsWarning: 48, .resumeHint: 40, .debugStrip: 50,
    ]
    private static let rail = CGSize(width: MapLayout.controlSize, height: MapLayout.railHeight)

    /// Every subset of the stack's elements, in the order the zone uses.
    private static func subsets() -> [[MapBottomItem]] {
        (0..<(1 << MapBottomItem.allCases.count)).map { mask in
            MapBottomItem.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
        }
    }

    private static func ordered(_ subset: [MapBottomItem]) -> [MapBottomItem] {
        MapBottomZone.items(
            offer: subset.contains(.offerCard), toast: subset.contains(.toast), status: subset.contains(.statusLine),
            positionStatus: subset.contains(.positionStatus), restoreStatus: subset.contains(.restoreStatus),
            roadsWarning: subset.contains(.roadsWarning), resumeHint: subset.contains(.resumeHint),
            debugSetting: subset.contains(.debugStrip))
    }

    @Test("the credit frame meets no bottom element and stays inside the container, for every combination")
    func creditNeverCovered() {
        var checked = 0
        for container in Self.containers {
            for scale in Self.heightScales {
                for subset in Self.subsets() {
                    let items = Self.ordered(subset).map {
                        (item: $0, size: CGSize(width: 600, height: (Self.baseHeight[$0] ?? 50) * scale))
                    }
                    let frames = MapBottomLayout.frames(
                        container: container, items: items, railSize: Self.rail, creditWidth: 190)
                    let credit = try! #require(frames.credit)
                    #expect(CGRect(origin: .zero, size: container).contains(credit))
                    #expect(!credit.intersects(frames.rail))
                    for placed in frames.items { #expect(!credit.intersects(placed.frame), "\(placed.item)") }
                    // The stack's elements do not overlap each other either.
                    for (a, b) in zip(frames.items, frames.items.dropFirst()) {
                        #expect(a.frame.maxY <= b.frame.minY)
                    }
                    checked += 1
                }
            }
        }
        #expect(checked == 2 * 2 * 256)
    }

    @Test("the stack ends above the credit band; the rail too; the stack stays left of the rail")
    func stackAboveBand() {
        let container = CGSize(width: 375, height: 667)
        let frames = MapBottomLayout.frames(
            container: container,
            items: [(.statusLine, CGSize(width: 900, height: 56)), (.roadsWarning, CGSize(width: 100, height: 48))],
            railSize: Self.rail, creditWidth: 190)
        let band = CGFloat(667 - MapLayout.attributionBand)
        let gap = CGFloat(MapLayout.aboveCreditGap)
        #expect(frames.items.map(\.item) == [.statusLine, .roadsWarning])
        #expect(frames.items.last!.frame.maxY == band - gap)
        #expect(frames.rail.maxY == band - gap)
        #expect(frames.items[0].frame.maxX <= frames.rail.minX)
        #expect(frames.items[1].frame.width == 100)
        // Credit: bottom band, right edge, one line.
        let credit = try! #require(frames.credit)
        #expect(credit.minY == band)
        #expect(credit.maxX == CGFloat(375 - MapLayout.edgeInset))
        #expect(credit.height == CGFloat(MapBottomLayout.creditHeight))
    }

    @Test("no pack in use: no credit frame, the same positions")
    func noCredit() {
        let a = MapBottomLayout.frames(container: CGSize(width: 375, height: 667), items: [], railSize: Self.rail, creditWidth: nil)
        let b = MapBottomLayout.frames(container: CGSize(width: 375, height: 667), items: [], railSize: Self.rail, creditWidth: 190)
        #expect(a.credit == nil)
        #expect(a.rail == b.rail)
    }

    @Test("the layout's bottom inset is the band plus the gap the view pads by")
    func insetMatchesView() {
        #expect(MapLayout.bottomInset() == MapLayout.attributionBand + MapLayout.aboveCreditGap)
        #expect(MapBottomLayout.creditHeight <= MapLayout.attributionBand)
    }
}

/// R-QA42-1: at accessibility Dynamic Type sizes the bottom stack is cut so it cannot grow over the speed card.
@Suite("Map bottom stack at accessibility sizes")
struct MapBottomLimitTests {
    private let all = MapBottomZone.items(
        offer: true, toast: true, status: true, positionStatus: true, restoreStatus: true,
        roadsWarning: true, resumeHint: true, debugSetting: true)

    @Test("normal sizes: nothing is dropped")
    func normalUnchanged() {
        #expect(MapBottomZone.limited(all, accessibilitySize: false) == all)
    }

    @Test("accessibility sizes: at most two, offer card and status banner kept, order kept")
    func accessibilityLimited() {
        let out = MapBottomZone.limited(all, accessibilitySize: true)
        #expect(out == [.offerCard, .statusLine])
        #expect(out.count == MapBottomZone.accessibilityLimit)
    }

    @Test("accessibility sizes: dropped least important first (position, debug, resume, restore, roads, toast)")
    func dropOrder() {
        #expect(MapBottomZone.limited([.statusLine, .positionStatus, .roadsWarning], accessibilitySize: true) == [.statusLine, .roadsWarning])
        #expect(MapBottomZone.limited([.toast, .statusLine, .roadsWarning], accessibilitySize: true) == [.toast, .statusLine])
        #expect(MapBottomZone.limited([.offerCard, .toast, .statusLine], accessibilitySize: true) == [.offerCard, .statusLine])
        #expect(MapBottomZone.limited([.restoreStatus, .positionStatus, .resumeHint, .debugStrip], accessibilitySize: true) == [.restoreStatus, .resumeHint])
    }

    @Test("accessibility sizes: an empty position-status slot goes first and never costs a visible line (R80.1-1)")
    func emptyPositionSlotDroppedFirst() {
        // Converged restored estimate, no road pack: positionStatus is in items but draws nothing.
        #expect(MapBottomZone.limited([.restoreStatus, .positionStatus, .roadsWarning], accessibilitySize: true) == [.restoreStatus, .roadsWarning])
        #expect(MapBottomZone.limited([.positionStatus, .roadsWarning, .resumeHint], accessibilitySize: true) == [.roadsWarning, .resumeHint])
    }

    @Test("accessibility sizes: an empty offer-card shell does not use up a place")
    func emptyOfferShell() {
        let items: [MapBottomItem] = [.offerCard, .statusLine, .positionStatus, .roadsWarning]
        #expect(MapBottomZone.limited(items, accessibilitySize: true, offerVisible: false) == [.offerCard, .statusLine, .roadsWarning])
        #expect(MapBottomZone.limited(items, accessibilitySize: true, offerVisible: true) == [.offerCard, .statusLine])
    }

    @Test("accessibility sizes: two or fewer pass through; the status banner and offer card survive any combination")
    func neverDropsCritical() {
        #expect(MapBottomZone.limited([.positionStatus, .debugStrip], accessibilitySize: true) == [.positionStatus, .debugStrip])
        for mask in 0..<(1 << MapBottomItem.allCases.count) {
            let subset = MapBottomItem.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let out = MapBottomZone.limited(subset, accessibilitySize: true)
            for critical in [MapBottomItem.statusLine, .offerCard] where subset.contains(critical) {
                #expect(out.contains(critical))
            }
            #expect(out.count <= max(MapBottomZone.accessibilityLimit, subset.filter { [.statusLine, .offerCard].contains($0) }.count))
        }
    }
}
