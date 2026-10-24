import Foundation
import Testing
@testable import DriveLogger

// UX-15: the link services' failure reasons. The English `text` is on-disk
// (link rows, `OBDLinkState.failed(reason:)`, console): frozen here. The
// screens show `display`, read back from the state's string.

/// One of each case, with payloads as the services produce them.
private let everyReason: [LinkReason] = [
    .noUARTPair(services: 0),
    .noUARTPair(services: 3),
    .characteristicVanished("FFF1"),
    .characteristicVanished("BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
    .serviceDiscoveryFailed("The connection has timed out unexpectedly."),
    .noServices,
    .notificationsRefused(characteristic: "FFE1", error: "Writing is not permitted."),
    .notificationsRefused(characteristic: "FFE1", error: nil),
    .sessionFailed,
    .bluetoothState(9),
]

@Suite("Link reasons: log text frozen, display translated")
struct LinkReasonTests {
    @Test("The logged text is byte-identical to the strings the services always wrote")
    func logTextFrozen() {
        #expect(LinkReason.noUARTPair(services: 3).text == "no notify + write characteristic pair in 3 service(s)")
        #expect(LinkReason.noUARTPair(services: 0).text == "no notify + write characteristic pair in 0 service(s)")
        #expect(LinkReason.characteristicVanished("FFF1").text == "characteristic FFF1 vanished")
        #expect(LinkReason.serviceDiscoveryFailed("boom").text == "service discovery failed: boom")
        #expect(LinkReason.noServices.text == "no GATT services")
        #expect(LinkReason.notificationsRefused(characteristic: "FFE1", error: "denied").text == "notifications on FFE1 refused: denied")
        #expect(LinkReason.notificationsRefused(characteristic: "FFE1", error: nil).text == "notifications on FFE1 refused: not notifying")
        #expect(LinkReason.sessionFailed.text == "ELM session failed")
        #expect(LinkReason.bluetoothState(9).text == "Bluetooth state 9")
    }

    @Test("Every text reads back as the same reason")
    func roundTrip() {
        for reason in everyReason {
            #expect(LinkReason(text: reason.text) == reason, "\(reason.text)")
        }
    }

    @Test("Anything else is not a link reason: ELM session failures, iOS errors, near misses")
    func otherTextsAreNotParsed() {
        for text in [
            "transport closed", "link lost", "connect failed", "ELM session failed ", "no GATT services.",
            BLEAvailability.Reason.unknown, "Bluetooth state ", "Bluetooth state 9x",
            "no notify + write characteristic pair in  service(s)", "no notify + write characteristic pair in 03 service(s)",
            "characteristic  vanished", "characteristic fff1 vanished", "characteristic FFF1 FFF2 vanished",
            "notifications on  refused: x", "notifications on FFE1 was refused",
            "", "something a service said",
        ] {
            #expect(LinkReason(text: text) == nil, "\(text)")
        }
    }

    @Test("The screens show the display value (en); an unknown reason is shown as written")
    func displayInEnglish() {
        #expect(LinkReason.noUARTPair(services: 3).display == "no notify + write characteristic pair (services: 3)")
        #expect(LinkReason.characteristicVanished("FFF1").display == "characteristic FFF1 vanished")
        #expect(LinkReason.serviceDiscoveryFailed("boom").display == "service discovery failed: boom")
        #expect(LinkReason.noServices.display == "no GATT services")
        #expect(LinkReason.notificationsRefused(characteristic: "FFE1", error: "denied").display == "notifications on FFE1 refused: denied")
        #expect(LinkReason.notificationsRefused(characteristic: "FFE1", error: nil).display == "notifications on FFE1 refused: not notifying")
        #expect(LinkReason.sessionFailed.display == "ELM session failed")
        #expect(LinkReason.bluetoothState(9).display == "Bluetooth state 9")
        for reason in everyReason {
            #expect(LinkReasonText.display(reason.text) == reason.display, "\(reason.text)")
            #expect(AdapterStatus(.failed(reason: reason.text)).detail == reason.display, "\(reason.text)")
        }
        // A Core ELMSession reason stays English, as written.
        #expect(AdapterStatus(.failed(reason: "transport closed")).detail == "transport closed")
        #expect(AdapterStatus(.unavailable(reason: LinkReason.bluetoothState(9).text)).detail == "Bluetooth state 9")
    }

    @Test("An unusable GATT layout fails the link with the English text the service logged")
    @MainActor
    func unusableKeepsLogText() async {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling })
        link.disconnect()
        link.connect(to: FakeBLECentral.adapterID)
        let text = LinkReason.noUARTPair(services: 2).text
        central.send(.unusable(FakeBLECentral.adapterID, table: [], reason: text, uptime: FakeBLECentral.now))
        #expect(await eventually { link.state == .failed(reason: "no notify + write characteristic pair in 2 service(s)") })
        #expect(RecordingSession.describe(link.state) == "failed (no notify + write characteristic pair in 2 service(s))")
        #expect(AdapterStatus(link.state).detail == "no notify + write characteristic pair (services: 2)")
    }

    @Test("The catalog has every display key with the approved Ukrainian text (fails until the UX-15 keys are merged)")
    func catalogHasUkrainian() throws {
        let catalog = try StringCatalog(path: "App/Resources/Localizable.xcstrings")
        let expected: [String: String] = [
            "no notify + write characteristic pair (services: %lld)": "немає пари характеристик notify і write (служб: %lld)",
            "characteristic %@ vanished": "характеристика %@ зникла",
            "service discovery failed: %@": "не вдалося знайти служби: %@",
            "no GATT services": "адаптер не має служб GATT",
            "not notifying": "сповіщення не ввімкнено",
            "notifications on %@ refused: %@": "адаптер відхилив сповіщення на %1$@: %2$@",
            "ELM session failed": "збій сеансу ELM",
            "Bluetooth state %lld": "Стан Bluetooth %lld",
        ]
        for (key, uk) in expected {
            let entry = catalog.entries[key]
            #expect(entry?.value("uk") == uk, "\(key)")
            #expect(entry?.state("uk") == "translated", "\(key)")
        }
    }
}
