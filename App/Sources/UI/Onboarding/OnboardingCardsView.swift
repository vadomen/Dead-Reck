import SwiftUI

/// The text of one card, no buttons. Scrolls when it does not fit (large
/// Dynamic Type). `showsTitle: false` is Settings → "Mount and orientation",
/// which shows card 3's text under its own navigation title.
struct OnboardingCardContent: View {
    let card: OnboardingCard
    var showsTitle = true
    @Environment(\.dynamicTypeSize) private var typeSize

    /// At the default sizes every card fits the smallest phone without
    /// scrolling: a small icon and a title one step down, tight gaps; the body
    /// text keeps its size. The accessibility sizes keep the roomy layout and scroll.
    private var compact: Bool { !typeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 12 : 20) {
                if showsTitle {
                    Image(systemName: card.systemImage)
                        .font(.system(size: compact ? 30 : 44, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(card.title)
                        .font(compact ? .title.bold() : .largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                }
                text
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, compact ? 8 : 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Where it scrolls, show it once so the driver's passenger sees more text follows.
        .scrollIndicatorsFlash(onAppear: !compact)
    }

    @ViewBuilder
    private var text: some View {
        switch card {
        case .howItWorks:
            paragraph(OnboardingText.howItWorksBody)
            attention(OnboardingText.driverAttention)
        case .adapter:
            paragraph(OnboardingText.adapterWorksWith)
            Link(destination: OnboardingText.vehiclesURL) {
                Text(OnboardingText.vehiclesLink)
                    .font(.title3.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
            }
            paragraph(OnboardingText.adapterSteps)
        case .mount:
            paragraph(OnboardingText.mountRigid)
            paragraph(OnboardingText.mountWiFi)
            paragraph(OnboardingText.mountAsk)
        case .arrow:
            paragraph(OnboardingText.arrowBody)
            paragraph(OnboardingText.arrowMapLayout)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.title3).fixedSize(horizontal: false, vertical: true)
    }

    /// The driver rule: smaller than the body but bold, on its own panel.
    private func attention(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.semibold))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

/// Page dots, one element for VoiceOver: "Card 2 of 4".
struct OnboardingDots: View {
    let current: OnboardingCard

    var body: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingCard.allCases) { card in
                Circle()
                    .fill(card == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingText.position(current))
    }
}

/// The paged cards with Next / Skip. Plain values and closures, so previews
/// need no model. The buttons sit outside the scrolling text: reachable at
/// every text size.
struct OnboardingCardsContent: View {
    @Binding var page: Int
    var showsSkip: Bool
    var primaryTitle: String
    var onPrimary: () -> Void = {}
    var onSkip: () -> Void = {}

    private var current: OnboardingCard {
        OnboardingCard.allCases[min(max(page, 0), OnboardingCard.allCases.count - 1)]
    }

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $page) {
                ForEach(OnboardingCard.allCases) { card in
                    OnboardingCardContent(card: card).tag(card.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Reading order: title and text (the page), then position, then buttons.
            .accessibilitySortPriority(3)
            OnboardingDots(current: current)
                .accessibilitySortPriority(2)
            VStack(spacing: 8) {
                Button(action: onPrimary) {
                    Text(primaryTitle).font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 56)
                }
                .prominentButton()
                if showsSkip {
                    Button(action: onSkip) {
                        Text(OnboardingText.skip).font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            // The buttons are pinned: at the accessibility sizes they filled almost half of a small
            // phone and left the text a window of three lines. They stay big (xxxLarge, 56 pt tall).
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilitySortPriority(1)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The cover, wired to the model.
struct OnboardingCardsView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingCardsContent(
            page: $model.page, showsSkip: model.showsSkip, primaryTitle: model.primaryTitle,
            onPrimary: { model.primary() }, onSkip: { model.skip() })
    }
}

/// Settings → "Mount and orientation": card 3's text, read only.
struct MountInfoScreen: View {
    var body: some View {
        OnboardingCardContent(card: .mount, showsTitle: false)
            .navigationTitle("Mount and orientation")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Card 1") { OnboardingCardsContent(page: .constant(0), showsSkip: true, primaryTitle: "Next") }
#Preview("Card 2") { OnboardingCardsContent(page: .constant(1), showsSkip: true, primaryTitle: "Next") }
#Preview("Card 3, dark") {
    OnboardingCardsContent(page: .constant(2), showsSkip: true, primaryTitle: "Next").preferredColorScheme(.dark)
}
#Preview("Card 4, last") { OnboardingCardsContent(page: .constant(3), showsSkip: true, primaryTitle: "Continue") }
#Preview("Card 1, review") { OnboardingCardsContent(page: .constant(0), showsSkip: false, primaryTitle: "Next") }
#Preview("Card 1, largest type") {
    OnboardingCardsContent(page: .constant(0), showsSkip: true, primaryTitle: "Next")
        .environment(\.dynamicTypeSize, .accessibility3)
}
#Preview("Mount and orientation") { NavigationStack { MountInfoScreen() } }
