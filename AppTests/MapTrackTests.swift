import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// Fixtures are small offsets around (0, 0); no real places.
private func fix(
    t: Double?, accuracy: Double = 5, lat: Double = 0.001, lon: Double = 0.001, age: Double = 0
) -> LocationSample {
    LocationSample(
        latitude: lat, longitude: lon, altitude: 0, horizontalAccuracy: accuracy,
        verticalAccuracy: 5, speed: 10, speedAccuracy: 1, course: 0, courseAccuracy: 5,
        receivedT: t.map { MonotonicTimestamp(seconds: $0) }, ageS: t == nil ? nil : age
    )
}

@Suite("GPSTrack")
struct MapTrackTests {
    @Test("Accuracy band boundaries")
    func bands() {
        #expect(AccuracyBand(accuracy: 15) == .good)
        #expect(AccuracyBand(accuracy: 15.01) == .fair)
        #expect(AccuracyBand(accuracy: 100) == .fair)
        #expect(AccuracyBand(accuracy: 100.01) == .poor)
        #expect(AccuracyBand(accuracy: 1000) == .poor)
        #expect(AccuracyBand(accuracy: 1000.01) == .bad)
        #expect(AccuracyBand(accuracy: -1) == nil)
        #expect(AccuracyBand(accuracy: .nan) == nil)
    }

    @Test("Invalid accuracy or coordinates are rejected")
    func rejects() {
        var track = GPSTrack()
        track.append(fix(t: 0, accuracy: -1))
        track.append(fix(t: 10, accuracy: .infinity))
        track.append(fix(t: 20, lat: .nan))
        track.append(fix(t: 30, lon: .infinity))
        #expect(track.points.isEmpty)
    }

    @Test("1 Hz fixes over 60 s are thinned to about 30 points")
    func thins() {
        var track = GPSTrack()
        for i in 0..<60 { track.append(fix(t: Double(i))) }
        #expect((29...31).contains(track.points.count))
    }

    @Test("Point time is receivedT minus age")
    func usesFixTime() {
        var track = GPSTrack()
        track.append(fix(t: 100, age: 1.5))
        #expect(track.points.first?.t == 98.5)
    }

    @Test("The same fix re-delivered is not added again")
    func dedupesByTime() {
        var track = GPSTrack()
        track.append(fix(t: 0))
        track.append(fix(t: 0))
        track.append(fix(t: 5))
        track.append(fix(t: 5))
        #expect(track.points.count == 2)
    }

    @Test("Identical coordinates with a new time still count")
    func identicalCoordinatesNewTime() {
        var track = GPSTrack()
        track.append(fix(t: 0))
        track.append(fix(t: 3))
        track.append(fix(t: 6))
        #expect(track.points.count == 3)
    }

    @Test("An earlier fix time is skipped")
    func skipsEarlier() {
        var track = GPSTrack()
        track.append(fix(t: 10))
        track.append(fix(t: 5))
        track.append(fix(t: 12))
        #expect(track.points.map(\.t) == [10, 12])
    }

    @Test("A fix without receivedT is skipped")
    func skipsWithoutReceivedT() {
        var track = GPSTrack()
        track.append(fix(t: nil))
        #expect(track.points.isEmpty)
    }

    @Test("10 000 fixes stay within the cap, keep first and last, and widen the spacing")
    func cap() {
        var track = GPSTrack()
        for i in 0..<10_000 { track.append(fix(t: Double(i) * 2)) }
        #expect(track.points.count <= GPSTrack.maxPoints)
        #expect(track.points.first?.t == 0)
        #expect(track.minInterval > GPSTrack.initialMinInterval)
        #expect(track.minInterval.truncatingRemainder(dividingBy: GPSTrack.initialMinInterval) == 0)
        // The newest accepted fix is the last point.
        let last = track.points.last?.t ?? -1
        #expect(last >= 19_999 - track.minInterval)
        // A steady drive stays one segment and one run, however far it is thinned.
        #expect(track.points.filter(\.segmentStart).count == 1)
        #expect(track.runs.count == 1)
    }

    @Test("Spacing beyond the gap threshold does not split a steady drive")
    func longDriveStaysOneSegment() {
        var track = GPSTrack()
        for i in 0..<100_000 { track.append(fix(t: Double(i) * 2)) }
        #expect(track.minInterval > GPSTrack.gapSeconds)
        #expect(track.gapThreshold >= 2 * track.minInterval)
        #expect(track.points.filter(\.segmentStart).count == 1)
        #expect(track.runs.count == 1)
    }

    @Test("Halving never bridges a gap, at odd or even indices")
    func halvingKeepsGaps() {
        var track = GPSTrack()
        var offset = 0.0
        for i in 0..<GPSTrack.maxPoints {
            if i == 100 || i == 201 || i == 700 || i == 1001 { offset += 100 }
            track.append(fix(t: Double(i) * 2 + offset))
        }
        #expect(track.minInterval == 4)
        #expect(track.points.filter(\.segmentStart).count == 5)
        for (a, b) in zip(track.points, track.points.dropFirst()) where !b.segmentStart {
            #expect(b.t - a.t <= GPSTrack.gapSeconds)
        }
        for run in track.runs {
            for (a, b) in zip(run.points, run.points.dropFirst()) {
                #expect(b.t - a.t <= GPSTrack.gapSeconds)
            }
        }
    }

    @Test("Halving keeps the first and the last point")
    func halvingKeepsEnds() {
        var track = GPSTrack()
        for i in 0..<GPSTrack.maxPoints { track.append(fix(t: Double(i) * 2)) }
        #expect(track.minInterval == 4)
        #expect(track.points.first?.t == 0)
        #expect(track.points.last?.t == Double(GPSTrack.maxPoints - 1) * 2)
    }

    @Test("A jump over 30 s starts a new segment and no run spans it")
    func gap() {
        var track = GPSTrack()
        for i in 0..<5 { track.append(fix(t: Double(i) * 2)) }
        for i in 0..<5 { track.append(fix(t: 100 + Double(i) * 2)) }
        #expect(track.points.filter(\.segmentStart).count == 2)
        let runs = track.runs
        #expect(runs.count == 2)
        for run in runs {
            let span = (run.points.last?.t ?? 0) - (run.points.first?.t ?? 0)
            #expect(span <= 30)
        }
    }

    @Test("Runs share endpoints and change on band change")
    func runs() {
        var track = GPSTrack()
        track.append(fix(t: 0, accuracy: 5))
        track.append(fix(t: 2, accuracy: 5))
        track.append(fix(t: 4, accuracy: 50))
        track.append(fix(t: 6, accuracy: 50))
        track.append(fix(t: 8, accuracy: 5))
        let runs = track.runs
        #expect(runs.map(\.band) == [.good, .fair, .good])
        #expect(runs[1].points.first == runs[0].points.last)
        #expect(runs[2].points.first == runs[1].points.last)
        #expect(runs[2].points.last?.t == 8)
    }
}

@MainActor
@Suite("MapViewModel")
struct MapViewModelTests {
    private let fileA = URL(fileURLWithPath: "/tmp/a.jsonl.gz")
    private let fileB = URL(fileURLWithPath: "/tmp/b.jsonl.gz")

    @Test("An inactive scene ingests nothing")
    func inactive() {
        let model = MapViewModel()
        model.ingest(fix(t: 0), file: fileA, isActive: false)
        #expect(model.track.points.isEmpty)
        #expect(model.latest == nil)
        #expect(model.currentFile == nil)
    }

    @Test("A new recording file resets the track")
    func newFileResets() {
        let model = MapViewModel()
        model.ingest(fix(t: 0), file: fileA, isActive: true)
        model.ingest(fix(t: 5), file: fileA, isActive: true)
        #expect(model.track.points.count == 2)
        model.ingest(fix(t: 1), file: fileB, isActive: true)
        #expect(model.track.points.count == 1)
        #expect(model.currentFile == fileB)
    }

    @Test("A nil fix keeps the track, also after Stop clears the file")
    func nilKeeps() {
        let model = MapViewModel()
        model.ingest(fix(t: 0), file: fileA, isActive: true)
        model.ingest(nil, file: fileA, isActive: true)
        model.ingest(nil, file: nil, isActive: true)
        #expect(model.track.points.count == 1)
        #expect(model.latest != nil)
        #expect(!model.isReceiving)
    }

    @Test("An old fix ingested late is already aged by its own time")
    func agedByFixTime() {
        let model = MapViewModel()
        model.ingest(fix(t: 100, age: 1), file: fileA, isActive: true, elapsed: 130)
        let age = ContinuousClock.now - (model.lastFixInstant ?? .now)
        #expect(age >= .seconds(30))
        #expect(age < .seconds(40))
    }

    @Test("A new file with no fix yet clears the previous drive")
    func newStartClears() {
        let model = MapViewModel()
        model.ingest(fix(t: 0), file: fileA, isActive: true)
        model.ingest(nil, file: fileB, isActive: true)
        #expect(model.track.points.isEmpty)
        #expect(model.latest == nil)
        #expect(!model.isReceiving)
    }

    @Test("A new fix stamps the arrival instant and marks receiving")
    func stampsArrival() {
        let model = MapViewModel()
        #expect(model.lastFixInstant == nil)
        model.ingest(fix(t: 0), file: fileA, isActive: true)
        #expect(model.lastFixInstant != nil)
        #expect(model.isReceiving)
        let stamp = model.lastFixInstant
        model.ingest(fix(t: 0), file: fileA, isActive: true)
        #expect(model.lastFixInstant == stamp)
    }
}

@MainActor
@Suite("Map camera and manual fixes")
struct MapManualFixTests {
    private let fileA = URL(fileURLWithPath: "/tmp/a.jsonl.gz")
    private let fileB = URL(fileURLWithPath: "/tmp/b.jsonl.gz")

    @Test("Span rule: max(500 m, 3 x accuracy), 500 m when invalid")
    func span() {
        #expect(MapFraming.spanMeters(horizontalAccuracy: 10) == 500)
        #expect(MapFraming.spanMeters(horizontalAccuracy: 200) == 600)
        #expect(MapFraming.spanMeters(horizontalAccuracy: 0) == 500)
        #expect(MapFraming.spanMeters(horizontalAccuracy: -1) == 500)
        #expect(MapFraming.spanMeters(horizontalAccuracy: .nan) == 500)
        #expect(MapFraming.spanMeters(horizontalAccuracy: .infinity) == 500)
    }

    @Test("Visible span from latitude delta")
    func visible() {
        #expect(MapFraming.visibleSpanMeters(latitudeDelta: 0.01) == 1113.2)
        #expect(MapFraming.visibleSpanMeters(latitudeDelta: 0) == nil)
        #expect(MapFraming.visibleSpanMeters(latitudeDelta: .nan) == nil)
    }

    @Test("Manual fixes are added, notes normalised, and reset on a new file")
    func fixList() {
        let model = MapViewModel()
        model.ingest(fix(t: 0), file: fileA, isActive: true)
        model.addManualFix(latitude: 0.001, longitude: 0.002, note: "  gate ")
        model.addManualFix(latitude: 0.003, longitude: 0.004, note: "   ")
        #expect(model.manualFixes.count == 2)
        #expect(model.manualFixes[0].note == "gate")
        #expect(model.manualFixes[1].note == nil)
        #expect(model.manualFixes[0].id != model.manualFixes[1].id)
        model.ingest(fix(t: 5), file: fileA, isActive: true)
        #expect(model.manualFixes.count == 2)
        model.ingest(fix(t: 1), file: fileB, isActive: true)
        #expect(model.manualFixes.isEmpty)
    }

    @Test("Disabled reason text")
    func reasons() {
        func gate(_ s: ManualFixSample.SpeedSource, _ kmh: Double?, _ ok: Bool) -> ManualFixAvailability {
            ManualFixAvailability(canRecord: ok, gate: .init(speedSource: s, speedKmh: kmh, isAllowed: ok))
        }
        #expect(ManualFixText.disabledReason(gate(.obd, 5, true)) == nil)
        #expect(ManualFixText.disabledReason(gate(.obd, 23, false)) == "Slow to ≤10 km/h to confirm (OBD 23 km/h)")
        #expect(ManualFixText.disabledReason(gate(.gps, 30.4, false)) == "Slow to ≤10 km/h to confirm (GPS 30 km/h)")
        let notRecording = ManualFixAvailability(
            canRecord: false, gate: .init(speedSource: .unknown, speedKmh: nil, isAllowed: true))
        #expect(ManualFixText.disabledReason(notRecording) == "Not recording")
    }
}
