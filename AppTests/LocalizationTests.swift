import Foundation
import DriveLoggerCore
import SwiftUI
import Testing
@testable import DriveLogger

// UX-15: Ukrainian + English. These tests guard the catalog, the rule that no
// user-facing text bypasses it, the permission texts, and the spoken phrases.
// Text that is DATA stays English on purpose (log values, Console protocol
// lines, developer diagnostic values); the allowlist below says why, per place.

// MARK: - The allowlist of literals that are not translated

enum LocalizationAllowlist {
    struct Entry {
        /// A path suffix, e.g. `Console/ConsoleViewModel.swift`.
        let file: String
        /// The literal contains this text; nil: every literal of the file.
        let needle: String?
        let reason: String
    }

    static let entries: [Entry] = [
        .init(file: "Console/ConsoleView.swift", needle: "ATI, AT@1", reason: "Console command placeholder: raw ELM327 protocol text"),
        .init(file: "Console/ConsoleViewModel.swift", needle: "AT", reason: "Console quick commands and the commands named in results: raw protocol"),
        .init(file: "Console/ConsoleViewModel.swift", needle: "protocol", reason: "Console adapter summary line: protocol data, English"),
        .init(file: "Console/ConsoleViewModel.swift", needle: "poll", reason: "Console adapter summary line: protocol data, English"),
        .init(file: "Console/ConsoleViewModel.swift", needle: " Hz", reason: "Console adapter summary line: protocol data, English"),
        .init(file: "Console/ConsoleViewModel.swift", needle: "TX", reason: "Console line direction prefix: raw protocol"),
        .init(file: "Console/ConsoleViewModel.swift", needle: "RX", reason: "Console line direction prefix: raw protocol"),
        .init(file: "Console/ConsoleViewModel.swift", needle: "→ ok", reason: "Console result titled with the raw command and the ELM outcome"),
        .init(file: "Map/MapHUD.swift", needle: "nav: idle", reason: "Developer debug strip value"),
        .init(file: "Map/MapNavigation.swift", needle: "ESS", reason: "Developer debug strip value"),
        .init(file: "Map/MapNavigation.swift", needle: "hdg", reason: "Developer debug strip value"),
        .init(file: "Map/MapNavigation.swift", needle: "scale", reason: "Developer debug strip value"),
        .init(file: "Map/MapNavigation.swift", needle: "dropped", reason: "Developer debug strip value"),
        .init(file: "Map/MapRoadsOverlay.swift", needle: "on road", reason: "Developer debug strip value"),
        .init(file: "Record/PreDriveChecklist.swift", needle: "rigid mount, fixed orientation", reason: "Written into the log header (`mount`): data, English"),
        .init(file: "Record/RecordingViewModel.swift", needle: "traffic jam", reason: "Mark preset: the value written to the log"),
        .init(file: "Record/RecordingViewModel.swift", needle: "bad road", reason: "Mark preset: the value written to the log"),
        .init(file: "Support/AppLanguage.swift", needle: "Українська", reason: "A language's own name (endonym): the same in every app language"),
        .init(file: "Support/AppLanguage.swift", needle: "English", reason: "A language's own name (endonym): the same in every app language"),
        .init(file: "Support/GPSVoice.swift", needle: "GPS ", reason: "GPSPhrase raw values: the phrase's identity (spoken text is `spoken`, from the catalog)"),
        .init(file: "Settings/NetworkDiagnostics.swift", needle: nil, reason: "Developer-only diagnostic values (English by decision); the row labels are String(localized:)"),
        .init(file: "Settings/RoadsDiagnostics.swift", needle: nil, reason: "navigation-engineer's developer diagnostic values and the OSM credit, English in both languages by decision"),
    ]

    static func allows(file: String, content: String) -> Int? {
        let text = content.replacingOccurrences(of: "\u{0}", with: "")
        return entries.firstIndex { entry in
            file.hasSuffix(entry.file) && (entry.needle.map { text.contains($0) } ?? true)
        }
    }
}

// MARK: - The scan

/// What counts as a localising call: a literal that is the first argument of one
/// of these is a catalog key (Text, Button, ... take a LocalizedStringKey; the
/// helpers named here take one too; `String(localized:)` and
/// `LocalizedStringResource` are the String-typed ways in).
private let acceptingCalls = [
    "SpeedTile(title:", "subtitle:", "resolved(", "BigButton(title:", "stat(", "linkRow(", "rowButton(",
    "String(localized:", "LocalizedStringResource(", "Text(", "Button(", "Label(", "Toggle(", "Section(",
    "LabeledContent(", ".navigationTitle(", ".accessibilityLabel(", ".accessibilityHint(", ".accessibilityValue(",
    ".confirmationDialog(", "ContentUnavailableView(", "TextField(", "Link(", "Picker(", "Menu(",
    "NavigationLink(", ".alert(", ".help(", ".accessibilityInputLabels(",
]

/// Contexts where a literal is an identifier, a format or a non-text value.
private let ignoredContexts = [
    "case ", "systemImage:", "systemName:", "Image(", "accessibilityIdentifier(", "forKey:", "Color(", "URL(string:",
    "@AppStorage(", "Logger(", "fatalError(", ".id(", "identifier:", "String(format:", "subsystem:", "category:",
    "symbol:", "URL(fileURLWithPath:", "kind:", "name:", "comment:",
]

private func ignoredContext(_ context: String) -> Bool {
    let trimmed = context.trimmingCharacters(in: .whitespaces)
    return ignoredContexts.contains { trimmed.hasSuffix($0) }
}

/// Looks like words a person reads: two letters in a row and a space or a capital start.
private func looksLikeText(_ content: String) -> Bool {
    let text = content.replacingOccurrences(of: "\u{0}", with: "")
    if content == "<multiline>" { return true }
    guard text.range(of: #"\p{L}{2,}"#, options: .regularExpression) != nil else { return false }
    return text.contains(" ") || text.first?.isUppercase == true || text.contains("…")
}

private func acceptingCall(_ context: String) -> String? {
    let trimmed = context.trimmingCharacters(in: .whitespaces)
    return acceptingCalls.first { trimmed.hasSuffix($0) }
}

@Suite("Localisation: nothing user-facing bypasses the catalog")
struct LocalizationScanTests {
    @Test("Every text-like literal in the UI sources is a catalog key or an allowlisted datum")
    func noUntranslatedLiterals() throws {
        var violations: [String] = []
        var usedAllowlist = Set<Int>()
        for file in LocalizationRepo.uiSourceFiles() {
            let scanned = SwiftLiteralScanner.scan(try LocalizationRepo.text(file))
            for literal in scanned.literals where !scanned.skippedLines.contains(literal.line) {
                if acceptingCall(literal.context) != nil { continue }
                if ignoredContext(literal.context) { continue }
                guard looksLikeText(literal.content) else { continue }
                if let index = LocalizationAllowlist.allows(file: file, content: literal.content) {
                    usedAllowlist.insert(index)
                    continue
                }
                violations.append("\(file):\(literal.line): \"\(literal.content.replacingOccurrences(of: "\u{0}", with: "\\(…)"))\"")
            }
        }
        #expect(violations.isEmpty, "Wrap in String(localized:) / a LocalizedStringKey parameter, or allowlist with a reason:\n\(violations.joined(separator: "\n"))")
        let stale = LocalizationAllowlist.entries.indices.filter { !usedAllowlist.contains($0) }
        #expect(stale.isEmpty, "Allowlist entries nothing matches any more: \(stale.map { LocalizationAllowlist.entries[$0].file + " " + (LocalizationAllowlist.entries[$0].needle ?? "*") })")
    }

    @Test("The path helper resolves symlinks: /tmp and /private/tmp spellings give the same relative paths")
    func pathsAreRobust() {
        let files = LocalizationRepo.allSourceFiles()
        #expect(files.contains("App/Sources/UI/Map/MapView.swift") && files.contains("App/Sources/Link/OBDLinkService.swift"))
        #expect(files.allSatisfy { !$0.hasPrefix("/") && !$0.contains("..") })
        #expect(Set(LocalizationRepo.uiSourceFiles()).isSubset(of: Set(files)))
        #expect(LocalizationRepo.root.path == LocalizationRepo.root.resolvingSymlinksInPath().path)
    }

    @Test("The scanner finds a bare literal and accepts a localising call (guards the scan itself)")
    func scannerSelfCheck() {
        let source = """
        struct V: View {
            var body: some View {
                Text("Hello there")
                Text(verbatim: "Hello there")
                let a = "Hello there"
                let b = String(localized: "Hello \\(1) there")
                // "Commented out text"
            }
        }
        #Preview { Text("Preview only text") }
        """
        let scanned = SwiftLiteralScanner.scan(source)
        let flagged = scanned.literals.filter {
            !scanned.skippedLines.contains($0.line) && acceptingCall($0.context) == nil && looksLikeText($0.content)
        }
        #expect(flagged.map(\.line) == [4, 5], "verbatim text and a bare let are flagged; Text(\"…\"), String(localized:), comments, previews are not")
    }

    @Test("Every key the code uses exists in Localizable.xcstrings")
    func everyUsedKeyIsInTheCatalog() throws {
        let catalog = try StringCatalog(path: "App/Resources/Localizable.xcstrings")
        let known = catalog.normalizedKeys
        var missing: [String] = []
        // All of App/Sources, services included (link, sensors, record, maps reasons).
        for file in LocalizationRepo.allSourceFiles() {
            let scanned = SwiftLiteralScanner.scan(try LocalizationRepo.text(file))
            for literal in scanned.literals where !scanned.skippedLines.contains(literal.line) {
                guard acceptingCall(literal.context) != nil, !literal.content.isEmpty, !literal.isMultiline else { continue }
                // `Text(verbatim:` never reaches here (its context ends in `verbatim:`).
                if !known.contains(StringCatalog.normalize(literal.content)) {
                    missing.append("\(file):\(literal.line): \"\(literal.content.replacingOccurrences(of: "\u{0}", with: "%@"))\"")
                }
            }
        }
        #expect(missing.isEmpty, "Keys used in code but missing from the catalog:\n\(missing.joined(separator: "\n"))")
    }
}

// MARK: - The catalog

@Suite("Localisation: Localizable.xcstrings is complete")
struct LocalizationCatalogTests {
    static let pluralKeys: Set<String> = [
        "%lld maps", "Download %lld maps · %@", "Download %lld maps · %@ on Wi-Fi", "%lld min ago", "%lld h ago",
        "Writing failed: %@. %lld events were not written.",
    ]

    @Test("The catalog is en-sourced, and every key has a non-empty, translated uk value")
    func everyKeyHasUkrainian() throws {
        let catalog = try StringCatalog(path: "App/Resources/Localizable.xcstrings")
        #expect(catalog.sourceLanguage == "en")
        #expect(catalog.entries.count > 300)
        var problems: [String] = []
        for (key, entry) in catalog.entries.sorted(by: { $0.key < $1.key }) {
            if let plural = entry.plural("uk") {
                for category in ["one", "few", "many", "other"] where (plural[category] ?? "").isEmpty {
                    problems.append("\(key): uk plural \(category) is empty or missing")
                }
                continue
            }
            guard let value = entry.value("uk"), !value.isEmpty else { problems.append("\(key): no uk value"); continue }
            if entry.state("uk") != "translated" { problems.append("\(key): uk state is \(entry.state("uk") ?? "nil")") }
            if value.contains("'") { problems.append("\(key): uk has an ASCII apostrophe (use ʼ)") }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("Plural keys carry uk one / few / many / other and en one / other")
    func pluralKeysAreComplete() throws {
        let catalog = try StringCatalog(path: "App/Resources/Localizable.xcstrings")
        for key in Self.pluralKeys {
            let entry = try #require(catalog.entries[key], "\(key) is not in the catalog")
            let uk = try #require(entry.plural("uk"), "\(key): no uk plural variations")
            #expect(Set(uk.keys) == ["one", "few", "many", "other"], "\(key): uk categories \(uk.keys.sorted())")
            let en = try #require(entry.plural("en"), "\(key): no en plural variations")
            #expect(Set(en.keys) == ["one", "other"], "\(key): en categories \(en.keys.sorted())")
        }
        // And no other entry has variations: a count in a sentence is a plural key.
        let others = catalog.entries.values.filter { $0.plural("uk") != nil && !Self.pluralKeys.contains($0.key) }
        #expect(others.isEmpty, "Unexpected plural entries: \(others.map(\.key))")
    }

    @Test("The uk text keeps the key's format arguments (same count and types)")
    func formatArgumentsSurvive() throws {
        let catalog = try StringCatalog(path: "App/Resources/Localizable.xcstrings")
        var problems: [String] = []
        for (key, entry) in catalog.entries where entry.plural("uk") == nil {
            guard let value = entry.value("uk") else { continue }
            let expected = StringCatalog.arguments(of: key)
            let actual = StringCatalog.arguments(of: value)
            if expected != actual { problems.append("\(key): key has \(expected), uk has \(actual)") }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("Units in uk are Ukrainian and sit behind a no-break space")
    func unitsAreCyrillic() throws {
        let catalog = try StringCatalog(path: "App/Resources/Localizable.xcstrings")
        #expect(catalog.entries["km/h"]?.value("uk") == "км/год")
        #expect(catalog.entries["%@ km/h"]?.value("uk") == "%@\u{00A0}км/год")
        #expect(catalog.entries["%@ MB"]?.value("uk") == "%@\u{00A0}МБ")
        #expect(catalog.entries["%@ V"]?.value("uk") == "%@\u{00A0}В")
        #expect(catalog.entries["%lld dBm"]?.value("uk") == "%lld\u{00A0}дБм")
        #expect(catalog.entries["OBD Hz"]?.value("uk") == "OBD Гц")
        #expect(catalog.entries["Motion Hz"]?.value("uk") == "Рух Гц")
        #expect(catalog.entries["%lld min ago"]?.plural("uk")?["many"] == "%lld\u{00A0}хв тому")
        #expect(catalog.entries["%lld h ago"]?.plural("uk")?["one"] == "%lld\u{00A0}год тому")
        // The OSM credit stays English in both languages, on the map and in About.
        #expect(catalog.entries["Road data © OpenStreetMap contributors, available under the Open Database License (ODbL) 1.0."]?
            .value("uk")?.contains("© OpenStreetMap contributors") == true)
    }
}

// MARK: - The permission texts

@Suite("Localisation: permission texts")
struct PermissionTextTests {
    /// logs/UK_GLOSSARY.md §5.2, verbatim.
    static let glossary: [String: String] = [
        "NSBluetoothAlwaysUsageDescription": "FuGPS підключається до Bluetooth-адаптера OBD-II у вашому авто, щоб зчитувати швидкість і дані двигуна й продовжувати визначати позицію, коли GPS глушать. Якщо ви записуєте поїздку, ці дані зберігаються в записі на вашому телефоні.",
        "NSMotionUsageDescription": "FuGPS використовує датчики руху телефона, щоб відстежувати повороти, гальмування й прискорення авто та продовжувати визначати позицію, коли GPS глушать. Якщо ви записуєте поїздку, ці дані зберігаються в записі на вашому телефоні.",
        "NSLocationWhenInUseUsageDescription": "FuGPS використовує вашу геолокацію, щоб показувати, де ви перебуваєте, продовжувати визначати позицію, коли GPS глушать (також із заблокованим екраном під час руху), і вибирати карту доріг для вашого району. Якщо ви записуєте поїздку, ваш маршрут зберігається в записі на вашому телефоні.",
    ]

    @Test("The 3 uk permission texts are in InfoPlist.xcstrings and match the glossary")
    func ukrainianPermissionTexts() throws {
        let catalog = try StringCatalog(path: "App/Resources/InfoPlist.xcstrings")
        #expect(catalog.sourceLanguage == "en")
        for (key, expected) in Self.glossary {
            let entry = try #require(catalog.entries[key], "\(key) is missing from InfoPlist.xcstrings")
            #expect(entry.value("uk") == expected, "\(key): uk text differs from the glossary")
            #expect(entry.state("uk") == "translated")
        }
    }

    @Test("The en permission texts in the catalog equal Info.plist's")
    func englishMatchesInfoPlist() throws {
        let catalog = try StringCatalog(path: "App/Resources/InfoPlist.xcstrings")
        let data = try Data(contentsOf: LocalizationRepo.file("App/Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for key in Self.glossary.keys {
            let base = try #require(plist[key] as? String)
            #expect(catalog.entries[key]?.value("en") == base, "\(key): InfoPlist.xcstrings en differs from Info.plist")
        }
        #expect(plist["CFBundleLocalizations"] as? [String] == ["en", "uk"])
        #expect(catalog.entries["CFBundleDisplayName"]?.value("uk") == "FuGPS", "the name is not translated")
    }
}

// MARK: - Spoken phrases

@Suite("Localisation: spoken GPS phrases")
struct SpokenPhraseTests {
    @Test("Spoken text per language; the identity (raw value) stays English")
    func phrases() {
        #expect(GPSPhrase.allCases.map(\.rawValue) == ["GPS lost", "GPS back", "GPS off"])
        #expect(GPSPhrase.allCases.map { $0.spoken(language: "en") } == ["GPS lost", "GPS back", "GPS off"])
        #expect(GPSPhrase.allCases.map { $0.spoken(language: "uk") } == ["GPS втрачено", "GPS відновлено", "GPS вимкнено"])
    }

    @Test("Settings footer quotes exactly the spoken phrases, in both languages")
    func footerQuotesEqualSpoken() {
        for (language, open, close) in [("en", "\"", "\""), ("uk", "«", "»")] {
            let footer = SettingsRows.speakGPSFootnote(language: language)
            for phrase in GPSPhrase.allCases {
                #expect(footer.contains("\(open)\(phrase.spoken(language: language))\(close)"),
                        "\(language): the footer does not quote «\(phrase.spoken(language: language))»: \(footer)")
            }
            // Three quoted phrases and no other quoted text.
            let marks = footer.components(separatedBy: open).count - 1
            let quoted = open == close ? marks / 2 : marks
            #expect(quoted == GPSPhrase.allCases.count, "\(language): \(footer)")
        }
        #expect(SettingsRows.speakGPSFootnote(language: "uk")
            == "Під час навігації або запису озвучує «GPS втрачено», «GPS відновлено» чи «GPS вимкнено» — не частіше ніж раз на 5 хвилин кожне.")
        #expect(SettingsRows.speakGPSFootnote(language: "en")
            == "While navigating or recording, says \"GPS lost\", \"GPS back\" or \"GPS off\", at most once every 5 minutes each.")
    }

    @Test("The announcer says the app-language text, not the identity")
    @MainActor
    func announcerSpeaksLocalised() {
        final class Speaker: GPSSpeaking { var said: [String] = []; func speak(_ text: String) { said.append(text) } }
        let speaker = Speaker()
        let voice = GPSVoiceAnnouncer(speaker: speaker, now: { 0 })
        voice.note(.ok, run: 1, enabled: true)
        voice.note(.none, run: 1, enabled: true)
        #expect(speaker.said == [GPSPhrase.lost.spoken])
    }

    @Test("The speech voice follows the app language")
    func voiceLanguage() {
        #expect(AppLanguage.voiceLanguage(appLanguage: "uk", systemVoiceLanguage: "en-US") == "uk-UA")
        #expect(AppLanguage.voiceLanguage(appLanguage: "uk", systemVoiceLanguage: "de-DE") == "uk-UA")
        #expect(AppLanguage.voiceLanguage(appLanguage: "en", systemVoiceLanguage: "en-GB") == "en-GB")
        #expect(AppLanguage.voiceLanguage(appLanguage: "en", systemVoiceLanguage: "de-DE") == "en-US")
    }
}

// MARK: - The compiled catalog, resolved for uk

private func resolved(_ resource: LocalizedStringResource, _ language: String) -> String {
    var r = resource
    r.locale = Locale(identifier: language)
    return String(localized: r)
}

@Suite("Localisation: the app bundle resolves uk")
struct LocalizationRuntimeTests {
    @Test("The app bundle ships en and uk")
    func bundleHasBothLanguages() {
        #expect(Set(Bundle.main.localizations).isSuperset(of: ["en", "uk"]))
        #expect(AppLanguage.code == "en", "the test scheme runs in English")
        #expect(AppLanguage.preferredLanguages == Bundle.main.preferredLocalizations)
    }

    @Test("Plain keys resolve in uk and en")
    func plainKeys() {
        #expect(resolved("Cancel", "uk") == "Скасувати")
        #expect(resolved("Cancel", "en") == "Cancel")
        #expect(resolved("Settings", "uk") == "Налаштування")
        #expect(resolved("Sessions", "uk") == "Записи")
        #expect(resolved("About", "uk") == "Про застосунок")
        #expect(resolved("Paired adapter", "uk") == "Ваш адаптер")
        #expect(resolved("Paired", "uk") == "Збережено")
        #expect(resolved("KEEP STILL  \(5) s", "uk") == "НЕ РУШАЙТЕ  5\u{00A0}с")
        #expect(resolved("Hold still — calibrating", "uk") == "Не рушайте — калібрування")
        #expect(resolved("Restored · \("5 хв тому") · not yet confirmed", "uk") == "Відновлено · 5 хв тому · ще не підтверджено")
    }

    @Test("Plurals: uk one / few / many, en one / other")
    func plurals() {
        let maps: [(Int, String, String)] = [
            (1, "1 карта", "1 map"), (2, "2 карти", "2 maps"), (4, "4 карти", "4 maps"), (5, "5 карт", "5 maps"),
            (11, "11 карт", "11 maps"), (12, "12 карт", "12 maps"), (21, "21 карта", "21 maps"), (22, "22 карти", "22 maps"),
            (0, "0 карт", "0 maps"),
        ]
        for (n, uk, en) in maps {
            #expect(resolved("\(n) maps", "uk") == uk)
            #expect(resolved("\(n) maps", "en") == en)
        }
        #expect(resolved("Download \(2) maps · \("1,5 МБ")", "uk") == "Завантажити 2 карти · 1,5 МБ")
        #expect(resolved("Download \(5) maps · \("1,5 МБ")", "uk") == "Завантажити 5 карт · 1,5 МБ")
        #expect(resolved("Download \(1) maps · \("1.5 MB") on Wi-Fi", "en") == "Download 1 map · 1.5 MB on Wi-Fi")
        #expect(resolved("Download \(3) maps · \("1,5 МБ") on Wi-Fi", "uk") == "Завантажити 3 карти · 1,5 МБ через Wi-Fi")
        // The restore line's three UX-20 strings.
        #expect(resolved("\(5) min ago", "uk") == "5\u{00A0}хв тому")
        #expect(resolved("\(2) h ago", "uk") == "2\u{00A0}год тому")
        #expect(resolved("\(5) min ago", "en") == "5 min ago")
        #expect(resolved("<1 min ago", "uk") == "<1\u{00A0}хв тому")
        // A plural on the second argument.
        #expect(resolved("Writing failed: \("disk"). \(1) events were not written.", "uk") == "Помилка запису: disk. Не записано 1 подію.")
        #expect(resolved("Writing failed: \("disk"). \(3) events were not written.", "uk") == "Помилка запису: disk. Не записано 3 події.")
        #expect(resolved("Writing failed: \("disk"). \(7) events were not written.", "uk") == "Помилка запису: disk. Не записано 7 подій.")
        #expect(resolved("Writing failed: \("disk"). \(1) events were not written.", "en") == "Writing failed: disk. 1 event was not written.")
        #expect(resolved("Writing failed: \("disk"). \(2) events were not written.", "en") == "Writing failed: disk. 2 events were not written.")
    }

    @Test("Positional arguments reorder in uk")
    func positional() {
        #expect(resolved("Card \(2) of \(4)", "uk") == "Картка 2 з 4")
        #expect(resolved("Not enough free space: \("1 МБ") free, \("2 МБ") needed. Delete old sessions first.", "uk")
            == "Недостатньо місця: вільно 1 МБ, потрібно 2 МБ. Спершу видаліть старі записи.")
        #expect(resolved("\("OBD") unavailable: \("причина")", "uk") == "Недоступно: OBD — причина")
    }

    @Test("Every catalog key resolves to its uk text through the compiled bundle")
    func compiledBundleMatchesCatalog() throws {
        // A sample across screens: if the catalog did not compile, the key itself would come back.
        let samples: [(LocalizedStringResource, String)] = [
            ("GPS lost", "GPS втрачено"), ("GPS back", "GPS відновлено"), ("GPS off", "GPS вимкнено"),
            ("GPS off (rail caption)", "GPS вимк."), ("OBD lost", "OBD втрачено"), ("Not now", "Не зараз"), ("Never", "Ніколи"),
            ("MARK", "ПОЗНАЧКА"), ("START", "ПОЧАТИ"), ("STOP", "СТОП"), ("km/h", "км/год"),
            ("NOT RECORDING", "ЗАПИС НЕ ТРИВАЄ"), ("Developer", "Розробник"), ("Thermal state", "Температура пристрою"),
        ]
        for (resource, expected) in samples {
            #expect(resolved(resource, "uk") == expected)
        }
        // The rail's captions keep the English text under a context key.
        #expect(resolved("GPS off (rail caption)", "en") == "GPS off")
    }
}

// MARK: - Display formats (locale-aware)

@Suite("Localisation: numbers, sizes and units follow the locale")
struct LocalizedFormatTests {
    private let en = Locale(identifier: "en_US")
    private let uk = Locale(identifier: "uk_UA")

    @Test("Decimals use the locale's separator")
    func decimals() {
        #expect(DisplayFormat.hz(9.8, locale: en) == "9.8")
        #expect(DisplayFormat.hz(9.8, locale: uk) == "9,8")
        #expect(DisplayFormat.hz(.nan, locale: uk) == "--")
        #expect(MapsText.size(48_000_000, locale: en) == "48.0 MB")
        // The unit word comes from the app-language catalog (en in this scheme), the separator from the locale.
        #expect(MapsText.size(48_000_000, locale: uk) == "48,0 MB")
    }

    @Test("Byte sizes come from ByteCountFormatStyle in the locale's unit names")
    func byteSizes() {
        #expect(DisplayFormat.bytes(48_200_000, locale: en) == "48.2 MB")
        #expect(DisplayFormat.bytes(48_200_000, locale: uk) == "48,2 МБ")
        #expect(DisplayFormat.bytes(2_500_000_000 as Int64, locale: uk) == "2,5 ГБ")
        #expect(DisplayFormat.bytes(1_500, locale: uk) == "2 кБ")
    }

    @Test("Voltage is a locale number plus the catalog's unit")
    func voltage() {
        #expect(DisplayFormat.voltage(12.4, locale: en) == "12.4 V")
        #expect(DisplayFormat.voltage(12.4, locale: uk) == "12,4 V", "separator from the locale; the unit word is the app language's (en here)")
        #expect(DisplayFormat.voltage(nil, locale: uk) == nil)
        #expect(resolved("\("12,4") V", "uk") == "12,4\u{00A0}В")
        #expect(AdapterStatus(.polling(protocolNumber: "6", voltage: 12.4)).detail?.hasPrefix("protocol 6 · ") == true)
    }

    @Test("Download progress is a percent style in the locale")
    func percent() {
        #expect(MapsText.stateText(.downloading(percent: 25), locale: en) == "Downloading 25%")
        #expect(MapsText.stateText(.downloading(percent: 25), locale: uk) == "Downloading 25%")
    }
}

// MARK: - Display labels of data, reasons, pack titles

@Suite("Localisation: data stays data")
struct LocalizedDataTests {
    @Test("Mark presets: the logged values stay English; the label is the display text")
    func markPresets() {
        #expect(MarkPreset.all == ["tunnel", "traffic jam", "junction", "bad road", "parking", "stop"])
        #expect(MarkPreset.all.map(MarkPreset.label(for:)) == ["Tunnel", "Traffic jam", "Junction", "Bad road", "Parking", "Stop"])
        #expect(MarkPreset.label(for: "my own spot") == "my own spot", "a custom marker is shown as typed")
        // Every preset has a Ukrainian label in the catalog.
        for key in ["Tunnel", "Traffic jam", "Junction", "Bad road", "Parking", "Stop"] {
            #expect(resolved(LocalizedStringResource(stringLiteral: key), "uk") != key, "\(key) has no uk label")
        }
    }

    @Test("The log header's mount text and the demo note are English data")
    func headerTextIsData() {
        #expect(PreDriveChecklist().mountForHeader == "rigid mount, fixed orientation (confirmed; no note)")
        #expect(PreDriveChecklist(mountNote: " vent clip ").mountForHeader == "vent clip")
    }

    @Test("Known Bluetooth reasons are translated for the screen; the constants (log text) are untouched")
    func linkReasons() {
        #expect(BLEAvailability.Reason.poweredOff == "Bluetooth is off")
        #expect(LinkReasonText.display(BLEAvailability.Reason.poweredOff) == "Bluetooth is off")
        #expect(LinkReasonText.display(BLEAvailability.Reason.unauthorized) == "Bluetooth permission denied")
        #expect(LinkReasonText.display(BLEAvailability.Reason.unsupported) == "Bluetooth LE is not supported on this device")
        #expect(LinkReasonText.display(BLEAvailability.Reason.resetting) == "Bluetooth is resetting")
        #expect(LinkReasonText.display(BLEAvailability.Reason.unknown) == "Bluetooth state unknown")
        #expect(LinkReasonText.display("something a service said") == "something a service said")
        #expect(resolved("Bluetooth permission denied", "uk") == "Доступ до Bluetooth заборонено")
        #expect(AdapterStatus(.unavailable(reason: BLEAvailability.Reason.unauthorized)).detail == "Bluetooth permission denied")
    }

    @Test("Pack titles follow the app's language, not Locale.preferredLanguages")
    func packTitlesFollowAppLanguage() throws {
        #expect(AppLanguage.preferredLanguages == Bundle.main.preferredLocalizations)
        let title = { (languages: [String]) in
            PackManifest.title(uk: "Українська назва", en: "English title", name: "zz-01", preferredLanguages: languages)
        }
        #expect(title(AppLanguage.preferredLanguages) == "English title", "the test scheme runs in English")
        #expect(title(["uk"]) == "Українська назва")
        // ["ru", "uk"] resolves the app to uk; the app list then says uk first, the raw device list would not.
        #expect(title(["ru", "uk"]) == "English title")
        // No call site hands the raw device list to the pack titles.
        for file in ["App/Sources/Maps/FirstLaunchMaps.swift", "App/Sources/Maps/PackOfferMonitor.swift",
                     "App/Sources/UI/Settings/MapsView.swift"] {
            let code = SwiftLiteralScanner.scan(try LocalizationRepo.text(file)).codeLines.joined(separator: "\n")
            #expect(!code.contains("Locale.preferredLanguages"), "\(file) must use AppLanguage.preferredLanguages")
        }
    }

    @Test("Screenshot fake `restored` shows the UX-20 line on an estimate (DEBUG launch argument)")
    @MainActor
    func restoredFake() {
        let fakes = HUDFakes.parse("ok,restored")
        #expect(fakes.isActive && fakes.restored && fakes.nav == .ellipse)
        let feed = MapPreviewData.fakeNav(.ellipse, restored: true)
        #expect(RestoreStatus.line(feed.restore) == "Restored · 12 min ago · not yet confirmed")
        #expect(MapPreviewData.fakeNav(.ellipse).restore == nil)
    }

    @Test("The background-risk sentence names the sensor in uk and keeps the identifier in en (pinned text)")
    func backgroundRiskNamesSensor() {
        let reasons: [RecordingSession.BackgroundRiskReason] = [.didNotStart(source: "referenceLocation")]
        #expect(RecordingSession.backgroundRiskText(reasons, language: "en").hasSuffix("GPS did not start."))
        let uk = RecordingSession.backgroundRiskText(reasons, language: "uk")
        #expect(uk.hasSuffix("GPS: не запущено."), "\(uk)")
        #expect(!uk.contains("referenceLocation"))
    }

    @Test("Service reasons shown on the Record and adapter screens go through the catalog")
    func serviceReasonsOnScreens() {
        let reason = SensorUnavailableReason.motionDenied
        let notice = DashboardState.make(DashboardState.Inputs(
            state: .idle, live: LiveStatus(), link: .idle, startBlocker: nil, allowsRecordingWithoutOBD: false,
            backgroundRisk: nil, lastStopReason: nil, unavailableSensors: [(name: "deviceMotion", reason: reason.rawValue)],
            simulatedAdapter: false, simulatedSensors: false, calibrationSeconds: 5)).notices.first?.text
        #expect(notice == "Motion unavailable: \(reason.display(language: "en"))")
        let uk = reason.display(language: "uk")
        #expect(uk.contains("Параметри iOS") && !uk.contains("налаштуван"))
        let failed = AdapterSettingsText.status(link: .failed(reason: LinkReason.noServices.text), adapterName: nil,
                                                hasRemembered: false, foundAdapter: false, waitedLong: false)
        #expect(failed.detail == LinkReason.noServices.display)
    }
}

@Suite("App language name (Settings → Language)")
struct AppLanguageNameTests {
    @Test("Own names for the shipped languages, regional codes included")
    func shipped() {
        #expect(AppLanguage.displayName(code: "en") == "English")
        #expect(AppLanguage.displayName(code: "uk") == "Українська")
        #expect(AppLanguage.displayName(code: "uk-UA") == "Українська")
        #expect(AppLanguage.displayName(code: "en-GB") == "English")
    }

    @Test("An unknown code falls back to the system's name, else the code itself")
    func fallback() {
        #expect(AppLanguage.displayName(code: "de") == "Deutsch")
        #expect(AppLanguage.displayName(code: "zzzz-QQ") == "zzzz-QQ")
        #expect(AppLanguage.displayName(code: "") == "")
    }

    @Test("The row's VoiceOver label names the current language; the footer and hint are in the catalog in uk")
    func rowTexts() {
        #expect(SettingsRows.languageAccessibilityLabel(name: "English") == "\(SettingsRows.languageTitle), English")
        #expect(resolved(LocalizedStringResource("Language"), "uk") == "Мова")
        #expect(resolved(LocalizedStringResource("Language"), "en") == "Language")
        #expect(resolved(LocalizedStringResource("To switch, add the other language in iOS Settings → General → Language & Region; then choose it here."), "uk")
            .hasPrefix("Щоб перемкнути, додайте другу мову в Параметри iOS"))
    }
}
