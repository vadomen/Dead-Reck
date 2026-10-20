import Foundation

/// What first-run onboarding (UX-18) has done on this phone: the info cards
/// were seen, and the one-time in-car mount confirmation was answered. Only
/// these two flags are stored. Separate from the maps step
/// (`FirstLaunchMapsStore`) and from Record's per-drive `PreDriveChecklist`.
///
/// **Migration from UX-1:** a phone that confirmed the old first-launch
/// checklist (`legacyChecklistKey` true) has read the mount text and ticked
/// "rigid mount" already, so both flags read true there. The legacy key is
/// only read here, never written.
struct OnboardingStore {
    static let cardsSeenKey = "onboarding.cardsSeen"
    static let mountConfirmedKey = "onboarding.mountConfirmed"
    /// The UX-1 checklist's key (`FirstLaunchStore.key`). An on-disk string:
    /// never rename it.
    static let legacyChecklistKey = "firstLaunch.checklistConfirmed"

    var defaults: UserDefaults = .standard

    /// The info cards were seen ("Got it" or skipped), or the legacy
    /// checklist was confirmed.
    var cardsSeen: Bool { defaults.bool(forKey: Self.cardsSeenKey) || legacyConfirmed }

    /// "Mounted" was tapped on the in-car card, or the legacy checklist was
    /// confirmed.
    var mountConfirmed: Bool { defaults.bool(forKey: Self.mountConfirmedKey) || legacyConfirmed }

    func markCardsSeen() { defaults.set(true, forKey: Self.cardsSeenKey) }

    func markMountConfirmed() { defaults.set(true, forKey: Self.mountConfirmedKey) }

    private var legacyConfirmed: Bool { defaults.bool(forKey: Self.legacyChecklistKey) }
}
