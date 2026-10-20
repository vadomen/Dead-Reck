import Observation

/// The paged info cards (UX-18 (1)): which card is up, and what the buttons do.
///
/// `.firstRun` is the cover on a fresh install: Skip and the last card's
/// Continue mark the cards seen (`OnboardingStore`), then the UX-8 maps step
/// follows. `.review` is Settings → "How FuGPS works": the same cards, read
/// only (Next / Done, no Skip), and it never touches the store.
@MainActor
@Observable
final class OnboardingModel {
    enum Mode: Equatable { case firstRun, review }

    let mode: Mode
    var isPresented: Bool
    /// Index into `OnboardingCard.allCases`; bound to the pager, so a swipe moves it.
    var page: Int

    @ObservationIgnored private let store: OnboardingStore

    /// - Parameter forcedCard: DEBUG `-uiOnboarding 1...4`: present at that
    ///   card (first run) even when already seen. Other values are ignored.
    init(mode: Mode = .firstRun, store: OnboardingStore = OnboardingStore(), forcedCard: Int? = nil) {
        self.mode = mode
        self.store = store
        let forced = forcedCard.flatMap { (1...OnboardingCard.allCases.count).contains($0) ? $0 - 1 : nil }
        page = forced ?? 0
        switch mode {
        case .firstRun: isPresented = forced != nil || !store.cardsSeen
        case .review: isPresented = false
        }
    }

    var card: OnboardingCard { OnboardingCard.allCases[min(max(page, 0), OnboardingCard.allCases.count - 1)] }
    var isLast: Bool { card == OnboardingCard.allCases.last }
    /// Review has no Skip (nothing to skip past), and the last card has none
    /// either: there Skip would do exactly what Continue does.
    var showsSkip: Bool { mode == .firstRun && !isLast }

    var primaryTitle: String {
        guard isLast else { return OnboardingText.next }
        return mode == .firstRun ? OnboardingText.continueTitle : OnboardingText.done
    }

    /// Settings → "How FuGPS works": from card 1.
    func show() {
        page = 0
        isPresented = true
    }

    /// Next on cards 1-3, the last card's Continue / Done.
    func primary() {
        if isLast { finish() } else { page += 1 }
    }

    /// Skip, on any card: the same end as the last card's Continue.
    func skip() {
        guard mode == .firstRun else { return }
        finish()
    }

    private func finish() {
        if mode == .firstRun { store.markCardsSeen() }
        isPresented = false
    }
}
