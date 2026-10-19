import Foundation
import Testing

@testable import DriveLoggerCore

/// UX-8 at-a-stop offer (prompt 26): 30 s outside, confident estimates only,
/// speed 0 for 3 s, never in motion, dialogs, once per region per drive,
/// Not now / Never, installed and excluded regions. Synthetic names and
/// boxes near (0, 0) only.
@Suite("Pack offer rule (UX-8 at a stop)")
struct PackOfferRuleTests {
    typealias R = PackOfferRule

    static func pack(_ name: String, _ kind: PackManifest.Pack.Kind = .region,
                     west: Double, south: Double, east: Double, north: Double) -> PackManifest.Pack {
        PackRegionChoiceTests.pack(name, kind, west: west, south: south, east: east, north: north)
    }

    static let manifest: [PackManifest.Pack] = [
        pack("zz-national", .national, west: 0, south: 0, east: 4, north: 3),
        pack("zz-01", west: 0, south: 0, east: 1, north: 1),
        pack("zz-02", west: 1, south: 0, east: 2, north: 1),
        pack("zz-04", west: 3, south: 2, east: 4, north: 3),
    ]

    static func box(west: Double, south: Double, east: Double, north: Double) -> RoadPackCoverage {
        RoadPackCoverage(rings: nil, bounds: RoadPackBounds(southLatE7: Int32(south * 1e7), westLonE7: Int32(west * 1e7),
                                                            northLatE7: Int32(north * 1e7), eastLonE7: Int32(east * 1e7)))
    }

    /// National (its coverage is the whole box: must be ignored) and zz-01.
    static let installed = [
        InstalledPackCoverage(name: "zz-national", coverage: box(west: 0, south: 0, east: 4, north: 3)),
        InstalledPackCoverage(name: "zz-01", coverage: box(west: 0, south: 0, east: 1, north: 1)),
    ]

    static let inZZ01 = R.Estimate(latitude: 0.5, longitude: 0.5, semiMajorM: 50)
    static let inZZ02 = R.Estimate(latitude: 0.3, longitude: 1.7, semiMajorM: 300)
    static let inZZ04 = R.Estimate(latitude: 2.5, longitude: 3.5, semiMajorM: 300)

    /// A test drive: one rule, one update per call.
    struct Drive {
        var rule = R()
        var excluded: Set<String> = ["zz-national", "zz-01"]
        var never: Set<String> = []
        var installed = PackOfferRuleTests.installed

        /// One update at `t`; the offered pack's name.
        @discardableResult
        mutating func at(_ t: Double, _ estimate: R.Estimate?, speed: Double?, dialog: Bool = false) -> String? {
            rule.update(R.Input(now: t, estimate: estimate, speedKmh: speed, dialogOpen: dialog,
                                installed: installed, manifestPacks: PackOfferRuleTests.manifest,
                                excluded: excluded, never: never))?.name
        }

        /// Updates at 1 Hz over `range`; every result.
        @discardableResult
        mutating func run(_ range: ClosedRange<Int>, _ estimate: R.Estimate?, speed: Double?,
                          dialog: Bool = false) -> [String?] {
            range.map { at(Double($0), estimate, speed: speed, dialog: dialog) }
        }
    }

    // MARK: Outside

    @Test("Needs 30 s continuously outside before a region is pending; nothing shows while moving")
    func thirtySecondsOutside() {
        var d = Drive()
        #expect(d.run(0...29, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
        #expect(d.rule.pendingRegion == nil)
        #expect(d.at(30, Self.inZZ02, speed: 0) == "zz-02")
        #expect(d.rule.offer?.size == 1_000)  // the card has the manifest pack (size, titles)

        var moving = Drive()
        #expect(moving.run(0...60, Self.inZZ02, speed: 50).allSatisfy { $0 == nil })
        #expect(moving.rule.pendingRegion == "zz-02")

        // A missing estimate resets the timer but keeps a pending region.
        var gap = Drive()
        gap.run(0...20, Self.inZZ02, speed: 50)
        gap.at(21, nil, speed: 50)
        gap.run(22...51, Self.inZZ02, speed: 50)
        #expect(gap.rule.pendingRegion == nil)
        gap.at(52, Self.inZZ02, speed: 50)
        #expect(gap.rule.pendingRegion == "zz-02")
        gap.run(53...60, nil, speed: 50)
        #expect(gap.rule.pendingRegion == "zz-02")
        #expect(gap.run(61...64, nil, speed: 0).last == "zz-02")
    }

    @Test("An unconfident estimate (semi-major > 1 km) never starts or continues the timer")
    func unconfident() {
        var d = Drive()
        let wide = R.Estimate(latitude: 0.3, longitude: 1.7, semiMajorM: 1_001)
        // Unconverged near zz-01's edge, outside it, at a stop for minutes: nothing.
        let nearEdge = R.Estimate(latitude: 0.5, longitude: 1.005, semiMajorM: 2_000)
        #expect(d.run(0...100, wide, speed: 0).allSatisfy { $0 == nil })
        #expect(d.run(101...300, nearEdge, speed: 0).allSatisfy { $0 == nil })
        #expect(d.rule.pendingRegion == nil)
        for bad in [Double.nan, .infinity, -1] {
            d.at(301, R.Estimate(latitude: 0.3, longitude: 1.7, semiMajorM: bad), speed: 0)
        }
        #expect(d.rule.pendingRegion == nil)
        // Confident from 400: offered at 430, not before. Exactly 1 km is confident.
        #expect(d.run(400...429, R.Estimate(latitude: 0.3, longitude: 1.7, semiMajorM: 1_000), speed: 0)
            .allSatisfy { $0 == nil })
        #expect(d.at(430, Self.inZZ02, speed: 0) == "zz-02")

        // One unconfident sample restarts the 30 s.
        var e = Drive()
        e.run(0...20, Self.inZZ02, speed: 50)
        e.at(21, wide, speed: 50)
        e.run(22...51, Self.inZZ02, speed: 50)
        #expect(e.rule.pendingRegion == nil)
    }

    @Test("Estimate inside an installed region coverage: no offer (only the estimate is input, never a raw fix)")
    func insideCoverage() {
        var d = Drive()
        #expect(d.run(0...300, Self.inZZ01, speed: 0).allSatisfy { $0 == nil })
        #expect(d.rule.pendingRegion == nil)
        // Back inside forgets the pending region: the next stop offers nothing.
        var back = Drive()
        back.run(0...40, Self.inZZ02, speed: 50)
        #expect(back.rule.pendingRegion == "zz-02")
        back.at(41, Self.inZZ01, speed: 50)
        #expect(back.rule.pendingRegion == nil)
        #expect(back.run(42...60, Self.inZZ01, speed: 0).allSatisfy { $0 == nil })
    }

    @Test("A national pack's coverage does not count; a pack not in the manifest does")
    func nationalIgnored() {
        var d = Drive()
        d.installed = [InstalledPackCoverage(name: "zz-national", coverage: Self.box(west: 0, south: 0, east: 4, north: 3))]
        #expect(d.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")
        var dev = Drive()
        dev.installed.append(InstalledPackCoverage(name: "zz-dev", coverage: Self.box(west: 1.5, south: 0.2, east: 1.9, north: 0.4)))
        #expect(dev.run(0...60, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
    }

    @Test("Outside in another region for 30 s: that one becomes pending")
    func regionChange() {
        var d = Drive()
        d.run(0...30, Self.inZZ02, speed: 50)
        #expect(d.rule.pendingRegion == "zz-02")
        d.run(31...60, Self.inZZ04, speed: 50)
        #expect(d.rule.pendingRegion == "zz-02")
        d.at(61, Self.inZZ04, speed: 50)
        #expect(d.rule.pendingRegion == "zz-04")
        #expect(d.run(62...65, Self.inZZ04, speed: 0).last == "zz-04")
        // 30 s outside every region bbox clears it.
        var e = Drive()
        e.run(0...30, Self.inZZ02, speed: 50)
        e.run(31...61, R.Estimate(latitude: 1.5, longitude: 2.5, semiMajorM: 100), speed: 50)
        #expect(e.rule.pendingRegion == nil)
    }

    // MARK: The stop

    @Test("The offer shows only at speed 0 held for 3 s; > 0 or unknown resets the stop")
    func stopNeeded() {
        var d = Drive()
        d.run(0...40, Self.inZZ02, speed: 50)
        #expect(d.at(41, Self.inZZ02, speed: 0) == nil)
        #expect(d.at(43, Self.inZZ02, speed: 0) == nil)
        #expect(d.at(43.9, Self.inZZ02, speed: 0) == nil)
        d.at(44, Self.inZZ02, speed: 0.5)  // 0.5 km/h is moving (the default stop speed is 0)
        d.at(45, Self.inZZ02, speed: 0)
        d.at(46, Self.inZZ02, speed: nil)  // unknown resets too
        d.at(47, Self.inZZ02, speed: 0)
        d.at(48, Self.inZZ02, speed: -1)  // iOS's invalid speed is unknown
        #expect(d.run(49...51, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
        #expect(d.at(52, Self.inZZ02, speed: 0) == "zz-02")
    }

    @Test("Never in motion: the card hides when the speed is > 0 or unknown, and does not come back this drive")
    func hidesInMotion() {
        var d = Drive()
        #expect(d.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")
        #expect(d.at(31, Self.inZZ02, speed: 0) == "zz-02")
        #expect(d.at(32, Self.inZZ02, speed: 3) == nil)
        #expect(d.run(33...100, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })

        var u = Drive()
        #expect(u.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")
        #expect(u.at(31, Self.inZZ02, speed: nil) == nil)
        #expect(u.run(32...60, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
    }

    @Test("A dialog open blocks the offer; one opening over the card hides it")
    func dialogBlocks() {
        var d = Drive()
        #expect(d.run(0...60, Self.inZZ02, speed: 0, dialog: true).allSatisfy { $0 == nil })
        #expect(d.at(61, Self.inZZ02, speed: 0) == "zz-02")  // not shown yet, so still offered once
        #expect(d.at(62, Self.inZZ02, speed: 0, dialog: true) == nil)
        #expect(d.run(63...90, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
    }

    // MARK: Once per region per drive, answers

    @Test("Once per region per drive; another region is still offered at a later stop")
    func oncePerRegion() {
        var d = Drive()
        #expect(d.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")
        d.run(31...40, Self.inZZ02, speed: 40)
        #expect(d.run(41...80, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
        d.run(81...120, Self.inZZ04, speed: 40)
        #expect(d.run(121...124, Self.inZZ04, speed: 0).last == "zz-04")
        d.run(125...200, Self.inZZ02, speed: 40)
        #expect(d.run(201...240, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
        #expect(d.rule.offered == ["zz-02", "zz-04"])
        // A new drive offers it again.
        var next = Drive()
        #expect(next.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")
    }

    @Test("Not now hides the card for this drive; Download hides it")
    func notNowAndDownload() {
        for answer in [R.Answer.notNow, .download] {
            var d = Drive()
            #expect(d.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")
            d.rule.answer(answer, region: "zz-02")
            #expect(d.rule.offer == nil)
            if answer == .download { d.excluded.insert("zz-02") }
            #expect(d.run(31...100, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
            d.run(101...110, Self.inZZ02, speed: 40)
            #expect(d.run(111...150, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
        }
        // An answer for another region leaves the card up.
        var d = Drive()
        d.run(0...30, Self.inZZ02, speed: 0)
        d.rule.answer(.notNow, region: "zz-04")
        #expect(d.rule.offer?.name == "zz-02")
    }

    @Test("Never: hidden, not offered while in the never set (new drive too); offered again on a new drive after a reset")
    func neverAndReset() {
        var d = Drive()
        #expect(d.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")
        d.rule.answer(.never, region: "zz-02")
        #expect(d.rule.offer == nil)
        let persisted: Set<String> = ["zz-02"]  // the caller persists it
        d.never = persisted
        #expect(d.run(31...100, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })

        var second = Drive()
        second.never = persisted
        #expect(second.run(0...100, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
        #expect(second.rule.pendingRegion == nil)

        // Settings resets "Never": the next drive offers it again.
        var third = Drive()
        third.never = persisted.subtracting(["zz-02"])
        #expect(third.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")

        // Never set while the card is up hides it.
        var fourth = Drive()
        fourth.run(0...30, Self.inZZ02, speed: 0)
        fourth.never = ["zz-02"]
        #expect(fourth.at(31, Self.inZZ02, speed: 0) == nil)
    }

    @Test("An installed, downloading or queued (excluded) region is not offered; excluding one hides its card")
    func excludedNotOffered() {
        var d = Drive()
        d.excluded.insert("zz-02")
        #expect(d.run(0...100, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
        #expect(d.rule.pendingRegion == nil)

        var e = Drive()
        #expect(e.run(0...30, Self.inZZ02, speed: 0).last == "zz-02")
        e.excluded.insert("zz-02")  // queued from Settings meanwhile
        #expect(e.at(31, Self.inZZ02, speed: 0) == nil)

        // Not in the manifest (e.g. no manifest yet): nothing to offer.
        var f = R()
        for t in 0...60 {
            f.update(R.Input(now: Double(t), estimate: Self.inZZ02, speedKmh: 0, dialogOpen: false,
                             installed: Self.installed, manifestPacks: [], excluded: [], never: []))
        }
        #expect(f.offer == nil && f.pendingRegion == nil)
    }

    @Test("Time going backwards or non-finite restarts the timers")
    func clock() {
        var d = Drive()
        d.run(100...120, Self.inZZ02, speed: 0)
        d.run(0...29, Self.inZZ02, speed: 0)
        #expect(d.rule.pendingRegion == nil && d.rule.offer == nil)
        #expect(d.at(.nan, Self.inZZ02, speed: 0) == nil)
        #expect(d.run(30...59, Self.inZZ02, speed: 0).allSatisfy { $0 == nil })
        #expect(d.at(60, Self.inZZ02, speed: 0) == "zz-02")
    }

    @Test("Deterministic: the same inputs give the same states")
    func deterministic() {
        var a = Drive(), b = Drive()
        a.run(0...40, Self.inZZ02, speed: 0)
        b.run(0...40, Self.inZZ02, speed: 0)
        #expect(a.rule == b.rule)
    }
}
