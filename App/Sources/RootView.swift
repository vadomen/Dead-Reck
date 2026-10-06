import DriveLoggerCore
import SwiftUI

/// Placeholder screen. Stands in for the recording UI, and proves the app links
/// against `DriveLoggerCore` and reads its own build identity.
struct RootView: View {
    private let info = AppInfo.read()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "car.side")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text(info.name)
                .font(.largeTitle.weight(.semibold))

            Text(info.displayVersion)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("Log format v\(LogFormatVersion.current.rawValue)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

#Preview {
    RootView()
}
