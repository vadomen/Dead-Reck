import Foundation
import Testing

@testable import DriveLogger

@Suite("UX-18: onboarding store and the UX-1 checklist migration")
struct OnboardingStoreTests {
    func defaults() -> UserDefaults {
        let name = "onboarding-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("The on-disk keys: two new ones, and the legacy checklist key unchanged")
    func keys() {
        #expect(OnboardingStore.cardsSeenKey == "onboarding.cardsSeen")
        #expect(OnboardingStore.mountConfirmedKey == "onboarding.mountConfirmed")
        #expect(OnboardingStore.legacyChecklistKey == "firstLaunch.checklistConfirmed")
    }

    @Test("A fresh install has seen nothing and confirmed nothing")
    func fresh() {
        let store = OnboardingStore(defaults: defaults())
        #expect(!store.cardsSeen)
        #expect(!store.mountConfirmed)
    }

    @Test("A confirmed UX-1 checklist reads as both seen and confirmed, and the legacy key is not written")
    func migration() {
        let d = defaults()
        d.set(true, forKey: OnboardingStore.legacyChecklistKey)
        let store = OnboardingStore(defaults: d)
        #expect(store.cardsSeen)
        #expect(store.mountConfirmed)
        // Read only: the new keys stay unset, nothing is copied over.
        #expect(d.object(forKey: OnboardingStore.cardsSeenKey) == nil)
        #expect(d.object(forKey: OnboardingStore.mountConfirmedKey) == nil)
    }

    @Test("A legacy key set to false migrates nothing")
    func legacyFalse() {
        let d = defaults()
        d.set(false, forKey: OnboardingStore.legacyChecklistKey)
        let store = OnboardingStore(defaults: d)
        #expect(!store.cardsSeen)
        #expect(!store.mountConfirmed)
    }

    @Test("Each mark persists on its own, across store instances, and never writes the legacy key")
    func marksPersist() {
        let d = defaults()
        OnboardingStore(defaults: d).markCardsSeen()
        #expect(OnboardingStore(defaults: d).cardsSeen)
        #expect(!OnboardingStore(defaults: d).mountConfirmed)
        OnboardingStore(defaults: d).markMountConfirmed()
        #expect(OnboardingStore(defaults: d).mountConfirmed)
        #expect(d.object(forKey: OnboardingStore.legacyChecklistKey) == nil)
    }

    @Test("Confirming the mount alone does not mark the cards seen")
    func mountAlone() {
        let d = defaults()
        OnboardingStore(defaults: d).markMountConfirmed()
        #expect(OnboardingStore(defaults: d).mountConfirmed)
        #expect(!OnboardingStore(defaults: d).cardsSeen)
    }
}
