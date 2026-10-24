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
