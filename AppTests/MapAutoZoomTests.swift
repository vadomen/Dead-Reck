import Foundation
import Testing

@testable import DriveLogger

/// Runs `seconds` of constant `speed` in 0.1 s steps.
private func run(_ zoom: inout AutoZoom, speed: Double?, seconds: Double) {
    var t = 0.0
    while t < seconds - 1e-9 {
        zoom.step(speedKmh: speed, dt: 0.1)
        t += 0.1
    }
}

@Suite("Speed-dependent zoom")
struct MapAutoZoomTests {
    @Test("Table: flat below 20, the four points, linear between, flat from 110")
    func table() {
        #expect(AutoZoom.target(kmh: 0) == 250)
        #expect(AutoZoom.target(kmh: 19.9) == 250)
        #expect(AutoZoom.target(kmh: 20) == 250)
        #expect(AutoZoom.target(kmh: 50) == 500)
        #expect(AutoZoom.target(kmh: 80) == 900)
        #expect(AutoZoom.target(kmh: 110) == 1500)
        #expect(AutoZoom.target(kmh: 150) == 1500)
        // Interpolation: 35 is halfway 20 to 50, 95 halfway 80 to 110.
        #expect(abs(AutoZoom.target(kmh: 35) - 375) < 1e-9)
        #expect(abs(AutoZoom.target(kmh: 65) - 700) < 1e-9)
        #expect(abs(AutoZoom.target(kmh: 95) - 1200) < 1e-9)
        #expect(AutoZoom.target(kmh: .nan) == 250)
    }

    @Test("Cold start is the slowest step, 250 m")
    func coldStart() {
        let zoom = AutoZoom()
        #expect(zoom.distance == 250)
        var held = zoom
        held.step(speedKmh: nil, dt: 1)
        #expect(abs(held.distance - 250) < 1e-9)
    }

    @Test("Smoothing: time constant 3 s on an injected dt, no wall clock")
    func smoothing() {
        var zoom = AutoZoom()
        zoom.step(speedKmh: 110, dt: 3)   // one time constant toward 1500 (log space)
        let expected = exp(log(250.0) + (log(1500.0) - log(250.0)) * (1 - exp(-1.0)))
        #expect(abs(zoom.distance - expected) < 1e-9)
        // Step size does not matter: 30 x 0.1 s equals 1 x 3 s.
        var fine = AutoZoom()
        run(&fine, speed: 110, seconds: 3)
        #expect(abs(fine.distance - expected) < 1e-6)
        run(&fine, speed: 110, seconds: 30)
        #expect(abs(fine.distance - 1500) < 1)
        // Bad dt changes nothing.
        let before = fine
        fine.step(speedKmh: 20, dt: 0)
        fine.step(speedKmh: 20, dt: .nan)
        #expect(fine == before)
    }

    @Test("Zooming out follows the speed at once; zooming in waits 6 s below the target")
    func asymmetry() {
        var zoom = AutoZoom()
        zoom.step(speedKmh: 80, dt: 0.1)
        #expect(zoom.latchedTarget == 900)
        run(&zoom, speed: 50, seconds: 5.5)
        #expect(zoom.latchedTarget == 900, "a dip shorter than the dwell changes nothing")
        run(&zoom, speed: 50, seconds: 1)
        #expect(zoom.latchedTarget == 500)
    }

    @Test("Hysteresis: stop-and-go 0 to 30 km/h does not pump")
    func stopAndGo() {
        var zoom = AutoZoom()
        run(&zoom, speed: 30, seconds: 20)            // settle
        var low = zoom.distance, high = zoom.distance
        for _ in 0..<12 {                             // 5 s stopped, 5 s at 30
            run(&zoom, speed: 0, seconds: 5)
            low = min(low, zoom.distance); high = max(high, zoom.distance)
            run(&zoom, speed: 30, seconds: 5)
            low = min(low, zoom.distance); high = max(high, zoom.distance)
        }
        #expect(high / low < 1.01, "the camera distance stays put")
        // A long stop does zoom in.
        run(&zoom, speed: 0, seconds: 30)
        #expect(zoom.distance < 270)
    }

    @Test("No speed source: the last distance is held, and the dwell is not advanced")
    func noSpeedHold() {
        var zoom = AutoZoom()
        run(&zoom, speed: 80, seconds: 30)
        let held = zoom.distance
        run(&zoom, speed: nil, seconds: 60)
        #expect(abs(zoom.distance - held) < 1)
        #expect(zoom.latchedTarget == 900)
        // Still the old target after the gap; only real low speed zooms in.
        run(&zoom, speed: 0, seconds: 5)
        #expect(zoom.latchedTarget == 900)
    }
}

@Suite("Follow zoom precedence")
struct FollowZoomPrecedenceTests {
    private func settled(at kmh: Double) -> FollowZoom {
        var zoom = FollowZoom()
        zoom.frame(distance: nil)
        zoom.cameraReported(distance: 1000)           // the frame's own report
        for _ in 0..<400 { zoom.step(speedKmh: kmh, dt: 0.1) }
        return zoom
    }

    @Test("Automatic: the write follows speed; a frame's report is not a driver zoom")
    func automatic() {
        var zoom = settled(at: 80)
        #expect(!zoom.driverOverride)
        let d = zoom.autoFollowDistance(headingUp: false, semiMajorM: nil)
        #expect(abs(d - 900) < 1)
    }

    @Test("A driver pinch is the distance until re-centre; speed is ignored meanwhile")
    func pinchOverride() {
        var zoom = settled(at: 80)
        _ = zoom.autoFollowDistance(headingUp: false, semiMajorM: nil)
        zoom.cameraReported(distance: 400)            // pinch
        #expect(zoom.driverOverride)
        for _ in 0..<100 { zoom.step(speedKmh: 110, dt: 0.1) }
        #expect(zoom.autoFollowDistance(headingUp: false, semiMajorM: nil) == 400)
        #expect(!zoom.autoWantsWrite(headingUp: false, semiMajorM: nil))
    }

    @Test("Re-centre and a new frame return to automatic")
    func recentre() {
        var zoom = settled(at: 50)
        zoom.cameraReported(distance: 400)
        zoom.recentre()
        #expect(!zoom.driverOverride)
        let d = zoom.autoFollowDistance(headingUp: false, semiMajorM: nil)
        #expect(abs(d - 500) < 1)
        zoom.cameraReported(distance: 300)
        #expect(zoom.driverOverride)
        zoom.frame(distance: nil)
        #expect(!zoom.driverOverride)
    }

    @Test("Our own writes, even a few steps old while the distance moves, are not a driver zoom")
    func ownWritesWhileMoving() {
        var zoom = settled(at: 20)
        var written: [Double] = []
        for _ in 0..<5 {
            for _ in 0..<3 { zoom.step(speedKmh: 110, dt: 0.1) }
            written.append(zoom.autoFollowDistance(headingUp: false, semiMajorM: nil))
        }
        #expect(written.last! > written.first!)
        zoom.cameraReported(distance: written[1])     // a report that lags three writes behind
        #expect(!zoom.driverOverride)
    }

    @Test("The ellipse fit wins when it needs a wider view, and not otherwise")
    func ellipse() {
        var zoom = settled(at: 20)                    // 250 m
        let narrow = zoom.autoFollowDistance(headingUp: true, semiMajorM: 5)
        #expect(abs(narrow - 250) < 1)
        let wide = zoom.autoFollowDistance(headingUp: true, semiMajorM: 400)
        #expect(wide > 1000, "an 880 m span fits the ellipse")
        // North-up never widens (unchanged).
        #expect(abs(zoom.autoFollowDistance(headingUp: false, semiMajorM: 400) - 250) < 1)
        // It also widens a driver zoom.
        zoom.cameraReported(distance: 200)
        #expect(zoom.autoFollowDistance(headingUp: true, semiMajorM: 400) > 1000)
        #expect(abs(zoom.autoFollowDistance(headingUp: true, semiMajorM: 1) - 200) < 1e-9)
    }

    @Test("A constant widened write is not drift; only the auto distance moving is (R26.1-1)")
    func widenedWriteIsNotDrift() {
        var zoom = settled(at: 10)                    // auto 250 m
        let written = zoom.autoFollowDistance(headingUp: true, semiMajorM: 100)
        #expect(written > 350, "widened well past the auto distance")
        for _ in 0..<100 {
            zoom.step(speedKmh: 10, dt: 0.1)
            #expect(!zoom.autoWantsWrite(headingUp: true, semiMajorM: 100))
        }
        // The auto distance drifts a lot: the widened distance follows it
        // once the ellipse no longer dominates.
        for _ in 0..<400 { zoom.step(speedKmh: 110, dt: 0.1) }
        #expect(zoom.autoWantsWrite(headingUp: true, semiMajorM: 100))
        // A growing ellipse alone still triggers a write.
        var other = settled(at: 10)
        _ = other.autoFollowDistance(headingUp: true, semiMajorM: 100)
        #expect(other.autoWantsWrite(headingUp: true, semiMajorM: 200))
    }

    @Test("Cold start writes 250 m")
    func cold() {
        var zoom = FollowZoom()
        #expect(zoom.autoFollowDistance(headingUp: false, semiMajorM: nil) == 250)
    }
}
