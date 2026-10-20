import Foundation
import Testing

/// The privacy manifest (`App/Resources/PrivacyInfo.xcprivacy`) against the
/// sources that ship in the app: `App/Sources` and `Core/Sources/DriveLoggerCore`
/// (linked in statically). The Mac-only CLIs under `Core/Sources` are not in
/// the app and are not scanned.
///
/// Every required-reason API category the sources use must have a manifest
/// entry with at least one reason, every reason must be one Apple defines for
/// that category, and no entry may be left for a category nothing uses.
///
/// The categories, their API symbols and their reason codes follow Apple's
/// "Describing use of required reason API" and the reason list Xcode's own
/// `.xcprivacy` editor offers (DVTCorePlistStructDefs). The scan matches
/// the Swift spellings of the listed symbols as whole identifiers, plus
/// `attributesOfItem`, which returns the creation and modification dates; it
/// errs towards matching too much, never too little. `//` comments are
/// ignored.
@Suite("Privacy manifest covers required-reason APIs")
struct RequiredReasonAPITests {
    typealias Repo = RepositoryInvariantTests

    static let manifestPath = "App/Resources/PrivacyInfo.xcprivacy"
    static let scannedDirectories = ["App/Sources", "Core/Sources/DriveLoggerCore"]

    /// One category: the identifiers that mean it is used, matched as whole
    /// identifier tokens (so `FileAttributeKey.creationDate` and
    /// `.creationDateKey` match, `statistics` does not).
    struct Category {
        /// `NSPrivacyAccessedAPIType` value.
        var key: String
        /// Any of these as a whole identifier.
        var identifiers: Set<String>
        /// Any of these as a whole identifier followed by `(` (C calls whose
        /// names are also ordinary words, such as `stat`).
        var calls: Set<String> = []
        /// Any identifier starting with one of these.
        var prefixes: [String] = []
        /// Every reason Apple defines for the category.
        var reasons: Set<String>
    }

    static let categories: [Category] = [
        Category(
            key: "NSPrivacyAccessedAPICategoryFileTimestamp",
            identifiers: Set(["creationDate", "modificationDate", "fileModificationDate", "fileCreationDate",
                              "contentModificationDate", "contentAccessDate", "attributeModificationDate",
                              "addedToDirectoryDate"].flatMap { [$0, $0 + "Key"] })
                .union(["attributesOfItem", "NSFileCreationDate", "NSFileModificationDate"]),
            calls: ["stat", "fstat", "fstatat", "lstat", "getattrlist", "getattrlistbulk", "fgetattrlist", "getattrlistat"],
            reasons: ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"]
        ),
        Category(
            key: "NSPrivacyAccessedAPICategorySystemBootTime",
            identifiers: ["systemUptime", "mach_absolute_time"],
            reasons: ["35F9.1", "8FFB.1", "3D61.1"]
        ),
        Category(
            key: "NSPrivacyAccessedAPICategoryDiskSpace",
            identifiers: ["systemFreeSize", "systemSize", "NSFileSystemFreeSize", "NSFileSystemSize"],
            calls: ["statfs", "statvfs", "fstatfs", "fstatvfs"],
            prefixes: ["volumeAvailableCapacity", "volumeTotalCapacity"],
            reasons: ["85F4.1", "E174.1", "7D9E.1", "B728.1"]
        ),
        Category(
            key: "NSPrivacyAccessedAPICategoryActiveKeyboards",
            identifiers: ["activeInputModes"],
            reasons: ["3EC4.1", "54BD.1"]
        ),
        Category(
            key: "NSPrivacyAccessedAPICategoryUserDefaults",
            identifiers: ["UserDefaults", "NSUserDefaults", "AppStorage"],
            reasons: ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"]
        ),
    ]

    /// The identifier tokens of `line` (ASCII letters, digits, `_`), each
    /// with whether a `(` follows it after optional spaces.
    static func tokens(of line: Substring) -> [(name: Substring, isCall: Bool)] {
        let bytes = Array(line.utf8)
        func isIdentifier(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
        }
        var result: [(Substring, Bool)] = []
        var i = 0
        while i < bytes.count {
            guard isIdentifier(bytes[i]) else { i += 1; continue }
            let start = i
            while i < bytes.count, isIdentifier(bytes[i]) { i += 1 }
            var j = i
            while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
            let name = Substring(decoding: bytes[start..<i], as: UTF8.self)
            result.append((name, j < bytes.count && bytes[j] == 0x28))
        }
        return result
    }

    static func matches(_ category: Category, _ tokens: [(name: Substring, isCall: Bool)]) -> Bool {
        tokens.contains { token in
            category.identifiers.contains(String(token.name))
                || (token.isCall && category.calls.contains(String(token.name)))
                || category.prefixes.contains { token.name.hasPrefix($0) }
        }
    }

    /// Category key → `path:line` of each use, comments stripped.
    static func uses(in files: [(path: String, text: String)]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for file in files {
            let lines = Repo.strippingLineComments(file.text).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let tokens = tokens(of: line)
                guard !tokens.isEmpty else { continue }
                for category in categories where matches(category, tokens) {
                    found[category.key, default: []].append("\(file.path):\(index + 1)")
                }
            }
        }
        return found
    }

    /// `NSPrivacyAccessedAPIType` → its reasons, from the manifest.
    static func declared(in manifest: [String: Any]) -> [String: [String]] {
        let entries = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        var result: [String: [String]] = [:]
        for entry in entries {
            guard let type = entry["NSPrivacyAccessedAPIType"] as? String else { continue }
            result[type, default: []] += entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        return result
    }

    /// Why the manifest does not match the uses, or empty.
    static func problems(uses: [String: [String]], declared: [String: [String]]) -> [String] {
        var problems: [String] = []
        let known = Dictionary(uniqueKeysWithValues: categories.map { ($0.key, $0.reasons) })
        for (key, sites) in uses.sorted(by: { $0.key < $1.key }) {
            guard let reasons = declared[key], !reasons.isEmpty else {
                problems.append("\(key) is used with no reason in \(manifestPath): \(sites.prefix(5).joined(separator: ", "))")
                continue
            }
        }
        for (key, reasons) in declared.sorted(by: { $0.key < $1.key }) {
            guard let allowed = known[key] else {
                problems.append("\(manifestPath) declares unknown category \(key)")
                continue
            }
            for reason in reasons where !allowed.contains(reason) {
                problems.append("\(manifestPath): \(reason) is not a reason for \(key)")
            }
            if uses[key] == nil {
                problems.append("\(manifestPath) declares \(key), which nothing in \(scannedDirectories) uses")
            }
        }
        return problems
    }

    static func sourceFiles() throws -> [(path: String, text: String)] {
        try scannedDirectories.flatMap { directory in
            try Repo.swiftFiles(under: directory).map { url in
                (Repo.relativePath(of: url), try String(contentsOf: url, encoding: .utf8))
            }
        }
    }

    // MARK: Tests

    @Test("Every required-reason API category used in App and DriveLoggerCore has a manifest entry with a valid reason")
    func manifestCoversSources() throws {
        let files = try Self.sourceFiles()
        #expect(files.contains { $0.path.hasPrefix("App/Sources/") }, "App not found from \(Repo.repositoryRoot.path)")
        #expect(files.contains { $0.path.hasPrefix("Core/Sources/DriveLoggerCore/") })
        let data = try Data(contentsOf: Repo.repositoryRoot.appendingPathComponent(Self.manifestPath))
        let manifest = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        let uses = Self.uses(in: files)
        #expect(!uses.isEmpty, "the scan found nothing: the patterns or the paths are broken")
        for problem in Self.problems(uses: uses, declared: Self.declared(in: manifest)) {
            Issue.record(Comment(rawValue: problem))
        }
    }

    @Test("The scan finds each category in typical code, and not in comments")
    func patternsMatchKnownSpellings() {
        let samples: [(String, String)] = [
            ("NSPrivacyAccessedAPICategoryFileTimestamp", "let d = values?.contentModificationDate"),
            ("NSPrivacyAccessedAPICategoryFileTimestamp", "let keys: [URLResourceKey] = [.creationDateKey]"),
            ("NSPrivacyAccessedAPICategoryFileTimestamp", "try fm.setAttributes([.modificationDate: now], ofItemAtPath: p)"),
            ("NSPrivacyAccessedAPICategoryFileTimestamp", "guard fstat(fd, &info) == 0 else {"),
            ("NSPrivacyAccessedAPICategoryFileTimestamp", "let a = try FileManager.default.attributesOfItem(atPath: p)"),
            ("NSPrivacyAccessedAPICategorySystemBootTime", "ProcessInfo.processInfo.systemUptime"),
            ("NSPrivacyAccessedAPICategorySystemBootTime", "let t = mach_absolute_time()"),
            ("NSPrivacyAccessedAPICategoryDiskSpace", "forKeys: [.volumeAvailableCapacityForImportantUsageKey])"),
            ("NSPrivacyAccessedAPICategoryDiskSpace", "attrs[.systemFreeSize]"),
            ("NSPrivacyAccessedAPICategoryDiskSpace", "statvfs(path, &info)"),
            ("NSPrivacyAccessedAPICategoryActiveKeyboards", "UITextInputMode.activeInputModes"),
            ("NSPrivacyAccessedAPICategoryUserDefaults", "UserDefaults.standard.bool(forKey: k)"),
            ("NSPrivacyAccessedAPICategoryUserDefaults", "@AppStorage(\"k\") private var flag = false"),
        ]
        for (key, line) in samples {
            let found = Self.uses(in: [(path: "Sample.swift", text: line)])
            #expect(found[key] == ["Sample.swift:1"], "\(key) not found in: \(line)")
        }
        let commented = Self.uses(in: [(path: "C.swift", text: "/// UserDefaults and systemUptime\nlet x = 1 // mach_absolute_time()")])
        #expect(commented.isEmpty)
        #expect(Self.uses(in: [(path: "N.swift", text: "let statistics = stat; let upstate = defaultsKey")]).isEmpty,
                "no partial identifiers; `stat` only as a call")
    }

    @Test("A used category without an entry, an unknown reason and a stale entry are each reported")
    func problemsAreReported() {
        let uses = ["NSPrivacyAccessedAPICategoryUserDefaults": ["A.swift:3"],
                    "NSPrivacyAccessedAPICategoryDiskSpace": ["B.swift:9"]]
        let declared = ["NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                        "NSPrivacyAccessedAPICategoryDiskSpace": ["C617.1"],
                        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]]
        let problems = Self.problems(uses: uses, declared: declared)
        #expect(problems.count == 2, "\(problems)")
        #expect(problems.contains { $0.contains("C617.1 is not a reason for NSPrivacyAccessedAPICategoryDiskSpace") })
        #expect(problems.contains { $0.contains("declares NSPrivacyAccessedAPICategorySystemBootTime, which nothing") })
        let missing = Self.problems(uses: uses, declared: ["NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]])
        #expect(missing == ["NSPrivacyAccessedAPICategoryDiskSpace is used with no reason in \(Self.manifestPath): B.swift:9"])
        #expect(Self.problems(uses: uses, declared: ["NSPrivacyAccessedAPICategoryUserDefaults": [],
                                                     "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"]]).count == 1,
                "an entry with no reason counts as missing")
    }
}
