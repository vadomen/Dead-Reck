import DriveLoggerCore
import Foundation
import Testing
@testable import DriveLogger

@Suite("Restore status line (UX-20)")
struct MapRestoreStatusTests {
    private func display(_ status: NavigationRestore.Status, age: Double = 720) -> RestoreDisplay {
        RestoreDisplay(
            status: status, reason: status == .unconfirmed ? nil : .fix,
            ageAtStartS: age, decidedAtS: status == .unconfirmed ? nil : 12)
    }

    @Test("Visible while unconfirmed, with the fixed age")
    func visibleWhileUnconfirmed() {
        #expect(RestoreStatus.line(display(.unconfirmed)) == "Restored \u{00B7} 12 min ago \u{00B7} not yet confirmed")
    }

    @Test("Hidden after confirmation, after rejection, and with no restore")
    func hidden() {
        #expect(RestoreStatus.line(display(.confirmed)) == nil)
        #expect(RestoreStatus.line(display(.rejected)) == nil)
        #expect(RestoreStatus.line(nil) == nil)
    }

    @Test("Age: under a minute, minutes, hours")
    func ageFormatting() {
        #expect(RestoreStatus.age(seconds: 0) == "<1 min ago")
        #expect(RestoreStatus.age(seconds: 59.9) == "<1 min ago")
        #expect(RestoreStatus.age(seconds: -5) == "<1 min ago")
        #expect(RestoreStatus.age(seconds: 60) == "1 min ago")
        #expect(RestoreStatus.age(seconds: 3_599) == "59 min ago")
        #expect(RestoreStatus.age(seconds: 3_600) == "1 h ago")
        #expect(RestoreStatus.age(seconds: 3 * 3_600 + 1_800) == "3 h ago")
        #expect(RestoreStatus.age(seconds: 23.9 * 3_600) == "23 h ago")
    }

    @Test("Bottom zone stacks the restore line above the finding line")
    func zoneOrder() {
        let items = MapBottomZone.items(
            offer: false, toast: false, status: false, positionStatus: true, restoreStatus: true,
            roadsWarning: false, resumeHint: false, debugSetting: false)
        #expect(items == [.restoreStatus, .positionStatus])
    }
}
