import Foundation

/// The four first-run info cards (UX-18 (1)), in order. The wording is fixed;
/// none of it advises the driver to touch the phone while moving (App Review 1.4.1).
enum OnboardingCard: Int, CaseIterable, Identifiable {
    case howItWorks, adapter, mount, arrow

    var id: Int { rawValue }

    /// "Card 2 of 4" counts from 1.
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .howItWorks: OnboardingText.howItWorksTitle
        case .adapter: OnboardingText.adapterTitle
        case .mount: OnboardingText.mountTitle
        case .arrow: OnboardingText.arrowTitle
        }
    }

    /// A decorative picture, hidden from VoiceOver.
    var systemImage: String {
        switch self {
        case .howItWorks: "car.fill"
        case .adapter: "cable.connector"
        case .mount: "iphone.gen3"
        case .arrow: "location.north.line.fill"
        }
    }
}

/// Wording of the cards, the Settings rows that reopen them and the buttons.
enum OnboardingText {
    static let howItWorksTitle = String(localized: "How FuGPS works")
    static let howItWorksBody = String(localized: "A Bluetooth OBD-II adapter reads your car's exact speed. The phone's sensors feel every turn. Road maps keep your position on the road. GPS helps when it's available; when it's jammed, FuGPS keeps going without it.")
    /// Visually distinct: not advice about the app, a rule for the driver.
    static let driverAttention = String(localized: "Don't use the phone while driving. Set it up before you set off.")

    static let adapterTitle = String(localized: "Connect your adapter")
    static let adapterWorksWith = String(localized: "FuGPS works with ELM327 Bluetooth LE adapters.")
    static let vehiclesLink = String(localized: "See which cars and adapters work")
    /// The site's vehicles page, on the same host as About's links.
    static let vehiclesURL = URL(string: AboutContent.siteRoot + "/vehicles.html")!
    static let adapterSteps = String(localized: "Plug the adapter into the car's OBD port, then pair it once in Settings → OBD adapter. After that, navigation starts by itself whenever the adapter connects.")

    static let mountTitle = String(localized: "Mount the phone")
    static let mountRigid = String(localized: "Use a rigid mount and keep the phone in the same position for the whole drive. The sensors can only measure the car if the phone doesn't move on its own.")
    static let mountWiFi = String(localized: "Keep Wi-Fi on: it helps the position when GPS is jammed.")
    static let mountAsk = String(localized: "The first time you navigate, FuGPS asks once whether the phone is mounted.")

    static let arrowTitle = String(localized: "Getting the arrow fast")
    static let arrowBody = String(localized: "The arrow appears once FuGPS knows your direction. Road maps and turns help it work this out while you drive. A passenger can speed it up: double-tap the map where you are while moving on a straight road. A pin while stopped fixes the position only, not the direction.")
    static let arrowMapLayout = String(localized: "On the map: speed, GPS and OBD status at the top left; Settings is the gear.")

    static let next = String(localized: "Next")
    static let skip = String(localized: "Skip")
    static let continueTitle = String(localized: "Continue")
    static let done = String(localized: "Done")

    /// VoiceOver's page position.
    static func position(_ card: OnboardingCard) -> String {
        String(localized: "Card \(card.number) of \(OnboardingCard.allCases.count)")
    }
}
