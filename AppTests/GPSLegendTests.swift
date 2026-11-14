import SwiftUI
import Testing
@testable import DriveLogger

@Suite("GPS legend: the raw-fix dot's key cannot drift from the map")
struct GPSLegendTests {
    @Test("Band boundaries classify exactly as before the bound constants")
    func boundaries() {
        #expect(AccuracyBand(accuracy: 0) == .good)
        #expect(AccuracyBand(accuracy: 15) == .good)
        #expect(AccuracyBand(accuracy: 15.0001) == .fair)
        #expect(AccuracyBand(accuracy: 100) == .fair)
        #expect(AccuracyBand(accuracy: 100.0001) == .poor)
        #expect(AccuracyBand(accuracy: 1000) == .poor)
        #expect(AccuracyBand(accuracy: 1000.1) == .bad)
        #expect(AccuracyBand(accuracy: .greatestFiniteMagnitude) == .bad)
        #expect(AccuracyBand(accuracy: -0.1) == nil)
        #expect(AccuracyBand(accuracy: -1) == nil)
        #expect(AccuracyBand(accuracy: .nan) == nil)
        #expect(AccuracyBand(accuracy: .infinity) == nil)
    }

    @Test("Each bound belongs to its own band; only the last band is unbounded")
    func boundsAreInclusive() {
        for band in AccuracyBand.allCases {
            guard let bound = band.upperBoundM else {
                #expect(band == AccuracyBand.allCases.last)
                continue
            }
            #expect(AccuracyBand(accuracy: bound) == band)
            #expect(AccuracyBand(accuracy: bound.nextUp) != band)
        }
    }

    @Test("Rows are the bands in order, then stale; swatches use the map's colour function")
    func rowsMatchMap() {
        let rows = GPSLegendContent.rows
        #expect(rows.map(\.kind) == [.estimate] + AccuracyBand.allCases.map { GPSLegendRow.Kind.band($0) } + [.stale])
        for row in rows {
            switch row.kind {
            case .estimate: #expect(row.color == EstimateDot.color)
            case .band(let band): #expect(row.color == GPSMapView.color(band, stale: false))
            case .stale: #expect(row.color == GPSMapView.color(.good, stale: true))
            }
        }
        #expect(Set(rows.map(\.text)).count == rows.count)
    }

    // String(localized:) groups digits by locale (1,000 m), so the expectation formats the same way.
    @Test("Thresholds in the text come from the bound constants and the stale rule")
    func textUsesConstants() throws {
        let good = try #require(AccuracyBand.good.upperBoundM)
        let fair = try #require(AccuracyBand.fair.upperBoundM)
        let poor = try #require(AccuracyBand.poor.upperBoundM)
        #expect(GPSLegendContent.text(for: .band(.good)).contains("\(Int(good)) m"))
        #expect(GPSLegendContent.text(for: .band(.fair)).contains("\(Int(fair)) m"))
        #expect(GPSLegendContent.text(for: .band(.poor)).contains("\(Int(poor).formatted()) m"))
        #expect(GPSLegendContent.text(for: .band(.bad)).contains("\(Int(poor).formatted()) m"))
        #expect(GPSLegendContent.staleSeconds == 5)
        #expect(GPSLegendContent.text(for: .stale).contains("\(GPSLegendContent.staleSeconds) s"))
    }

    @Test("Stale is grey whatever the band")
    func staleIsGrey() {
        for band in AccuracyBand.allCases { #expect(GPSMapView.color(band, stale: true) == .gray) }
    }
}
