import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

private func resolved(_ resource: LocalizedStringResource, _ language: String) -> String {
    var r = resource
    r.locale = Locale(identifier: language)
    return String(localized: r)
}

/// R-QA42-1 (prompt 43): the map explains refused Motion / Location permissions.
@Suite("Map permission line")
struct MapPermissionNoticeTests {
    private let motion = SensorUnavailableReason.motionDenied.availability
    private let location = SensorUnavailableReason.locationDenied.availability

    @Test("SensorAccess reads refused permissions from the sources' availability reasons")
    func accessFromAvailability() {
        #expect(SensorAccess.from([]).isGranted)
        #expect(SensorAccess.from([.available, .available]).isGranted)
        #expect(SensorAccess.from([.available, motion]) == SensorAccess(motionDenied: true, locationDenied: false))
        #expect(SensorAccess.from([location, .available]) == SensorAccess(motionDenied: false, locationDenied: true))
        #expect(SensorAccess.from([motion, location]) == SensorAccess(motionDenied: true, locationDenied: true))
        #expect(SensorAccess.from([SensorUnavailableReason.motionRestricted.availability]).motionDenied)
        #expect(SensorAccess.from([SensorUnavailableReason.locationRestricted.availability]).locationDenied)
        // Unrelated reasons (no barometer) are not a permission.
        #expect(SensorAccess.from([SensorUnavailableReason.barometerUnsupported.availability]).isGranted)
    }

    @Test("Motion wins over Location; nothing refused or the demo: no line; re-grant removes it")
    func choice() {
        #expect(MapPermissionNotice.make(SensorAccess(motionDenied: true, locationDenied: true), demo: false) == .motionDenied)
        #expect(MapPermissionNotice.make(SensorAccess(motionDenied: true), demo: false) == .motionDenied)
        #expect(MapPermissionNotice.make(SensorAccess(locationDenied: true), demo: false) == .locationDenied)
        #expect(MapPermissionNotice.make(SensorAccess(locationDenied: true), demo: true) == nil)
        #expect(MapPermissionNotice.make(SensorAccess(), demo: false) == nil, "after re-grant")
    }

    @Test("Finding your position is suppressed only while Motion is refused")
    func positionStatusSuppressed() {
        #expect(!MapPermissionNotice.showsPositionStatus(hasEstimate: true, notice: .motionDenied))
        #expect(MapPermissionNotice.showsPositionStatus(hasEstimate: true, notice: .locationDenied))
        #expect(MapPermissionNotice.showsPositionStatus(hasEstimate: true, notice: nil))
        #expect(!MapPermissionNotice.showsPositionStatus(hasEstimate: false, notice: nil))
    }

    @Test("Texts in en and uk; the OBD starting-point note belongs to Location only")
    func texts() {
        #expect(resolved("No motion access — navigation without GPS is not possible", "en")
            == "No motion access — navigation without GPS is not possible")
        #expect(resolved("No motion access — navigation without GPS is not possible", "uk")
            == "Немає доступу до датчиків руху — навігація без GPS неможлива")
        #expect(resolved("No location access — the map can't show where you are", "uk")
            == "Немає доступу до геолокації — карта не знає, де ви")
        #expect(resolved("Open iOS Settings (map line)", "en") == "Settings")
        #expect(resolved("Open iOS Settings (map line)", "uk") == "Параметри")
        #expect(resolved("OBD navigation needs a starting point — place a pin on the map", "uk")
            == "Навігації за OBD потрібна початкова точка — поставте мітку на карті")
        #expect(MapPermissionNotice.motionDenied.note == nil)
        #expect(MapPermissionNotice.locationDenied.note != nil)
        #expect(MapPermissionNotice.locationDenied.accessibilityLabel.hasSuffix(MapPermissionNotice.buttonTitle))
    }

    @Test("Bottom stack: the line sits under the status line; at AX sizes it is kept and the offer yields, max 2")
    func stack() {
        let all = MapBottomZone.items(
            offer: true, toast: true, status: true, positionStatus: true, restoreStatus: true,
            roadsWarning: true, resumeHint: true, debugSetting: true, permission: true)
        let order = all.firstIndex(of: .statusLine)!
        #expect(all[order + 1] == .permissionLine)
        #expect(MapBottomZone.limited(all, accessibilitySize: false) == all)
        let ax = MapBottomZone.limited(all, accessibilitySize: true)
        #expect(ax == [.statusLine, .permissionLine])
        #expect(MapBottomZone.limited([.offerCard, .permissionLine], accessibilitySize: true) == [.offerCard, .permissionLine])
        #expect(MapBottomZone.limited([.offerCard, .permissionLine, .roadsWarning], accessibilitySize: true) == [.offerCard, .permissionLine])
        // Without the line the offer is still never dropped.
        #expect(MapBottomZone.limited([.offerCard, .toast, .statusLine], accessibilitySize: true) == [.offerCard, .statusLine])
    }

    @Test("DEBUG fakes: motionDenied / locationDenied")
    func fakes() {
        #expect(HUDFakes.parse("ok,motionDenied").access == SensorAccess(motionDenied: true))
        #expect(HUDFakes.parse("locationDenied").access == SensorAccess(locationDenied: true))
        #expect(HUDFakes.parse("ok").access.isGranted)
    }

    @Test("R80.2-1: the feed publishes whether Finding your position draws, from the seeded display")
    @MainActor
    func positionFinding() {
        func display(converged: Bool, major: Double) -> NavDisplay {
            NavDisplay(
                position: GeoPoint(latitude: 0.001, longitude: 0.002), semiMajorM: major, semiMinorM: 8,
                orientationDeg: 0, headingDeg: 90, headingStdDeg: converged ? 3 : 30, converged: converged)
        }
        #expect(NavigationFeed(display: display(converged: false, major: 20)).positionFinding)
        #expect(NavigationFeed(display: display(converged: true, major: 5_000)).positionFinding, "km-wide ellipse")
        #expect(!NavigationFeed(display: display(converged: true, major: 20)).positionFinding)
        #expect(!NavigationFeed(display: nil).positionFinding)
    }
}
