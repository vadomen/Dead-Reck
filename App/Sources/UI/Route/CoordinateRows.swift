import SwiftUI

/// What the search sheet shows for typed coordinates and links (prompt 53a): ONE
/// row at the top of the results, above the completer's. Views only read the
/// flow; the reading of the text is `CoordinateParser`.
struct CoordinateInputRow: View {
    var flow: RouteFlowModel

    var body: some View {
        switch flow.input {
        case .none: EmptyView()
        case .point(let point):
            row(title: point.name ?? String(localized: "Coordinates"), subtitle: point.formatted, symbol: "mappin.and.ellipse") {
                flow.selectCoordinates()
            }
        case .swapped(let point):
            row(title: String(localized: "Coordinates, swapped"), subtitle: point.formatted, symbol: "arrow.left.arrow.right") {
                flow.selectCoordinates()
            }
        case .shortLink(let url):
            row(title: String(localized: "Open link"), subtitle: url.host ?? "", symbol: "link") { flow.openLink() }
        case .outOfRange:
            message(String(localized: "Latitude is between −90 and 90, longitude between −180 and 180."))
        case .noPoint:
            message(RouteFormat.noPointMessage)
        }
    }

    private func row(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: RouteBarLayout.fieldHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(HUDColors.warn).padding(.vertical, 8)
    }
}

/// The system Paste control for the empty search state: iOS shows no pasteboard
/// prompt, because the driver's tap on this very control is the permission.
struct SearchPasteButton: View {
    var onPaste: (String) -> Void

    var body: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let first = strings.first else { return }
            Task { @MainActor in onPaste(first) }
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.roundedRectangle)
        .frame(minHeight: RouteBarLayout.minTapTarget)
    }
}
