import SwiftUI

/// Wording of the one-time in-car mount card (UX-18 (2)).
enum MountCardText {
    static let question = String(localized: "Phone mounted and won't move?")
    static let confirm = String(localized: "Mounted")
}

/// The card, in the map's bottom-left zone in the offer card's slot (above the
/// Navigate status line). Plain values, for previews; the model's `isVisible`
/// decides when it shows and `confirm()` is the button.
struct MountConfirmationCardView: View {
    var onConfirm: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MountCardText.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            Button(action: onConfirm) {
                Text(MountCardText.confirm).font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
            }
            .prominentButton()
        }
        .padding(12)
        .hudSurface(RoundedRectangle(cornerRadius: 16))
        // Like the offer card: must not grow over the speed readout at AX3+.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Mount card") {
    MountConfirmationCardView().padding(40).background(Color(.systemGray4))
}

#Preview("Mount card, dark") {
    MountConfirmationCardView().padding(40).background(Color(.systemGray4)).preferredColorScheme(.dark)
}

#Preview("Mount card, largest allowed type") {
    MountConfirmationCardView().padding(40).background(Color(.systemGray4))
        .environment(\.dynamicTypeSize, .accessibility5)
}
