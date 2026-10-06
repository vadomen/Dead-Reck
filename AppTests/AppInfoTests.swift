import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

@Suite("AppInfo")
struct AppInfoTests {
    @Test("Reads name and version from an Info.plist dictionary")
    func readsBundleKeys() {
        let info = AppInfo.read(infoDictionary: [
            "CFBundleName": "DriveLogger",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "42",
        ])

        #expect(info.name == "DriveLogger")
        #expect(info.version == "0.1.0")
        #expect(info.build == "42")
        #expect(info.displayVersion == "0.1.0 (42)")
    }

    @Test("Falls back rather than crashing on a missing key")
    func fallsBackOnMissingKeys() {
        // A recording's header must always identify a build, even if the plist
        // is somehow incomplete — better a marked-unknown version than no log.
        let info = AppInfo.read(infoDictionary: [:])
        #expect(info.name == AppInfo.fallbackName)
        #expect(info.version == AppInfo.fallbackVersion)
        #expect(info.build == AppInfo.fallbackBuild)
    }

    @Test("Falls back when there is no Info dictionary at all")
    func fallsBackOnNilDictionary() {
        #expect(AppInfo.read(infoDictionary: nil).name == AppInfo.fallbackName)
    }

    @Test("The real app bundle carries the keys the logger needs")
    func realBundleIsConfigured() {
        // Catches an Info.plist that lost CFBundleVersion in a project
        // regeneration, which would otherwise only show up in recorded data.
        let info = AppInfo.read()
        #expect(info.version != AppInfo.fallbackVersion)
        #expect(info.build != AppInfo.fallbackBuild)
    }

    @Test("Converts to the Core identity written into log headers")
    func convertsToCoreIdentity() {
        let info = AppInfo.read(infoDictionary: [
            "CFBundleName": "DriveLogger",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "7",
        ])
        #expect(
            info.identity == AppIdentity(name: "DriveLogger", version: "1.2.3", build: "7")
        )
    }
}

@Suite("Info.plist permissions and capabilities")
struct InfoPlistTests {
    var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    @Test(
        "Every permission the logger requests has a purpose string",
        arguments: [
            "NSBluetoothAlwaysUsageDescription",
            "NSMotionUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
        ]
    )
    func hasPurposeString(key: String) {
        // A missing purpose string is a silent permission denial at runtime, and
        // an App Store rejection.
        let value = info[key] as? String
        #expect(value?.isEmpty == false, "\(key) is missing or empty")
    }

    @Test("Background modes cover recording with the screen off")
    func declaresBackgroundModes() {
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        #expect(modes.contains("bluetooth-central"))
        #expect(modes.contains("location"))
    }

    @Test("Recordings are reachable from the Files app")
    func exposesDocuments() {
        // Without both of these, a drive can only be retrieved by rebuilding
        // from Xcode, which loses the recording on the next install.
        #expect(info["UIFileSharingEnabled"] as? Bool == true)
        #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
    }

    @Test("Portrait-only on iPhone")
    func locksOrientation() {
        let orientations = info["UISupportedInterfaceOrientations"] as? [String] ?? []
        #expect(orientations == ["UIInterfaceOrientationPortrait"])
    }
}
