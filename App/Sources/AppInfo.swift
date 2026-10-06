import DriveLoggerCore
import Foundation

/// Build identity read from the app bundle.
///
/// Also produces the `AppIdentity` stamped into every recording's header, so a
/// drive can always be traced back to the build that produced it — which matters
/// when a sensor-handling bug is found after the fact.
struct AppInfo: Hashable, Sendable {
    let name: String
    let version: String
    let build: String

    static let fallbackName = "DriveLogger"
    static let fallbackVersion = "0.0"
    static let fallbackBuild = "0"

    static func read(from bundle: Bundle = .main) -> AppInfo {
        read(infoDictionary: bundle.infoDictionary)
    }

    /// Split out from `read(from:)` so the fallbacks are testable without
    /// standing up a bundle.
    static func read(infoDictionary: [String: Any]?) -> AppInfo {
        AppInfo(
            name: infoDictionary?["CFBundleName"] as? String ?? fallbackName,
            version: infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion,
            build: infoDictionary?["CFBundleVersion"] as? String ?? fallbackBuild
        )
    }

    /// Marketing version with the build number, e.g. `0.1.0 (1)`.
    var displayVersion: String {
        "\(version) (\(build))"
    }

    var identity: AppIdentity {
        AppIdentity(name: name, version: version, build: build)
    }
}
