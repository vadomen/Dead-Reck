import Foundation

/// Shared helpers of the UX-15 localisation tests: where the repository is, the
/// string catalog as data, and a small Swift string-literal scanner for the
/// "nothing user-facing bypasses the catalog" rule.
enum LocalizationRepo {
    /// The repository root, from this file's own path (AppTests/ is one level down).
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    static func file(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: file(path), encoding: .utf8)
    }

    /// Every `.swift` file under `App/Sources/UI`, plus `RootView.swift`: the places
    /// where text meets the screen. Relative paths, sorted.
    static func uiSourceFiles() -> [String] {
        let base = file("App/Sources/UI")
        var out: [String] = []
        if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        out.append("App/Sources/RootView.swift")
        return out.sorted()
    }
}

/// `Localizable.xcstrings` / `InfoPlist.xcstrings` read as plain JSON.
struct StringCatalog {
    struct Entry {
        let key: String
        let localizations: [String: [String: Any]]

        /// Plain `stringUnit` value for `language`, nil for plural entries.
        func value(_ language: String) -> String? {
            (localizations[language]?["stringUnit"] as? [String: Any])?["value"] as? String
        }

        func state(_ language: String) -> String? {
            (localizations[language]?["stringUnit"] as? [String: Any])?["state"] as? String
        }

        /// Plural category -> value, from top-level variations or from the first substitution.
        func plural(_ language: String) -> [String: String]? {
            let loc = localizations[language]
            var plural = (loc?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            if plural == nil, let subs = loc?["substitutions"] as? [String: Any],
               let first = subs.values.first as? [String: Any] {
                plural = (first["variations"] as? [String: Any])?["plural"] as? [String: Any]
            }
            guard let plural else { return nil }
            var out: [String: String] = [:]
            for (category, unit) in plural {
                out[category] = ((unit as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
            return out
        }
    }

    let sourceLanguage: String
    let entries: [String: Entry]

    init(path: String) throws {
        let data = try Data(contentsOf: LocalizationRepo.file(path))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        sourceLanguage = json["sourceLanguage"] as? String ?? ""
        var map: [String: Entry] = [:]
        for (key, raw) in (json["strings"] as? [String: Any]) ?? [:] {
            let locs = ((raw as? [String: Any])?["localizations"] as? [String: [String: Any]]) ?? [:]
            map[key] = Entry(key: key, localizations: locs)
        }
        entries = map
    }

    /// The keys with `%@` / `%lld` / ... replaced by one marker, as the scanner sees source literals.
    var normalizedKeys: Set<String> { Set(entries.keys.map(Self.normalize)) }

    static func normalize(_ key: String) -> String {
        key.replacingOccurrences(
            of: #"%(\d+\$)?(lld|ld|llu|lu|d|u|@|lf|f|\.\d+f)"#, with: "\u{0}", options: .regularExpression)
    }

    /// Format arguments of `text` as position -> type ("@", "lld"...). Sequential
    /// specifiers count up from 1; positional ones (`%2$lld`) say where they are.
    static func arguments(of text: String) -> [Int: String] {
        guard let regex = try? NSRegularExpression(pattern: #"%(?:(\d+)\$)?(lld|ld|llu|lu|d|u|@|lf|f|\.\d+f)"#) else { return [:] }
        var out: [Int: String] = [:]
        var next = 1
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let type = ns.substring(with: match.range(at: 2))
            if match.range(at: 1).location != NSNotFound, let n = Int(ns.substring(with: match.range(at: 1))) {
                out[n] = type
            } else {
                out[next] = type
                next += 1
            }
        }
        return out
    }
}

/// One string literal in a Swift file.
struct SourceLiteral {
    let line: Int
    /// The literal's text; an interpolation `\(...)` is one U+0000.
    let content: String
    /// The ~80 bytes before the opening quote, whitespace collapsed: what the literal is an argument of.
    let context: String
    let isMultiline: Bool
}

/// Splits Swift source into string literals and "code with strings and comments
/// blanked" lines. Just enough of the lexer for UI files (no raw strings).
enum SwiftLiteralScanner {
    struct Result {
        var literals: [SourceLiteral] = []
        /// One entry per source line, strings and comments replaced by spaces.
        var codeLines: [String] = []
        /// 1-based line numbers whose literals are exempt: previews, DEBUG-only code, after a Previews/Fakes marker.
        var skippedLines: Set<Int> = []
    }

    static func scan(_ source: String) -> Result {
        let b = Array(source.utf8)
        let n = b.count
        var result = Result()
        var code = [UInt8]()
        code.reserveCapacity(n)
        var i = 0
        var line = 1

        func isQuote(_ k: Int) -> Bool { k < n && b[k] == UInt8(ascii: "\"") }

        while i < n {
            let c = b[i]
            if c == UInt8(ascii: "\n") { line += 1; code.append(c); i += 1; continue }
            if c == UInt8(ascii: "/"), i + 1 < n, b[i + 1] == UInt8(ascii: "/") {
                while i < n, b[i] != UInt8(ascii: "\n") { code.append(UInt8(ascii: " ")); i += 1 }
                continue
            }
            if c == UInt8(ascii: "/"), i + 1 < n, b[i + 1] == UInt8(ascii: "*") {
                var depth = 0
                while i < n {
                    if b[i] == UInt8(ascii: "/"), i + 1 < n, b[i + 1] == UInt8(ascii: "*") { depth += 1; code.append(32); code.append(32); i += 2; continue }
                    if b[i] == UInt8(ascii: "*"), i + 1 < n, b[i + 1] == UInt8(ascii: "/") {
                        depth -= 1; code.append(32); code.append(32); i += 2
                        if depth == 0 { break }
                        continue
                    }
                    if b[i] == UInt8(ascii: "\n") { line += 1; code.append(b[i]) } else { code.append(32) }
                    i += 1
                }
                continue
            }
            if c == UInt8(ascii: "\"") {
                let context = collapsedContext(b, before: i)
                if i + 2 < n, b[i + 1] == UInt8(ascii: "\""), b[i + 2] == UInt8(ascii: "\"") {
                    let startLine = line
                    var j = i + 3
                    while j + 2 < n, !(b[j] == UInt8(ascii: "\"") && b[j + 1] == UInt8(ascii: "\"") && b[j + 2] == UInt8(ascii: "\"")) {
                        if b[j] == UInt8(ascii: "\n") { line += 1 }
                        j += 1
                    }
                    for k in i..<min(j + 3, n) { code.append(b[k] == UInt8(ascii: "\n") ? b[k] : 32) }
                    result.literals.append(SourceLiteral(line: startLine, content: "<multiline>", context: context, isMultiline: true))
                    i = min(j + 3, n)
                    continue
                }
                var j = i + 1
                var content = [UInt8]()
                while j < n, b[j] != UInt8(ascii: "\""), b[j] != UInt8(ascii: "\n") {
                    if b[j] == UInt8(ascii: "\\"), j + 1 < n {
                        if b[j + 1] == UInt8(ascii: "(") {
                            var depth = 1
                            var k = j + 2
                            while k < n, depth > 0 {
                                if b[k] == UInt8(ascii: "\"") {
                                    k += 1
                                    while k < n, b[k] != UInt8(ascii: "\"") { if b[k] == UInt8(ascii: "\\") { k += 1 }; k += 1 }
                                } else if b[k] == UInt8(ascii: "(") {
                                    depth += 1
                                } else if b[k] == UInt8(ascii: ")") {
                                    depth -= 1
                                }
                                k += 1
                            }
                            content.append(0)
                            j = k
                            continue
                        }
                        // Escapes: \" \\ \n \t \u{...}; the catalog key holds the plain character.
                        let e = b[j + 1]
                        if e == UInt8(ascii: "u"), j + 2 < n, b[j + 2] == UInt8(ascii: "{"),
                           let close = (j + 3..<n).first(where: { b[$0] == UInt8(ascii: "}") }),
                           let value = UInt32(String(decoding: b[(j + 3)..<close], as: UTF8.self), radix: 16),
                           let scalar = Unicode.Scalar(value) {
                            content.append(contentsOf: Array(String(Character(scalar)).utf8))
                            j = close + 1
                            continue
                        }
                        switch e {
                        case UInt8(ascii: "n"): content.append(10)
                        case UInt8(ascii: "t"): content.append(9)
                        default: content.append(e)
                        }
                        j += 2
                        continue
                    }
                    content.append(b[j])
                    j += 1
                }
                let end = min(j + 1, n)
                code.append(UInt8(ascii: "\""))
                for _ in (i + 1)..<max(i + 1, end - 1) { code.append(32) }
                if end - 1 > i { code.append(UInt8(ascii: "\"")) }
                result.literals.append(SourceLiteral(
                    line: line, content: String(decoding: content, as: UTF8.self), context: context, isMultiline: false))
                i = end
                continue
            }
            code.append(c)
            i += 1
        }
        result.codeLines = String(decoding: code, as: UTF8.self).components(separatedBy: "\n")
        result.skippedLines = skippedLines(source: source, code: result.codeLines)
        return result
    }

    private static func collapsedContext(_ b: [UInt8], before i: Int) -> String {
        let start = max(0, i - 80)
        let text = String(decoding: b[start..<i], as: UTF8.self)
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + (text.last?.isWhitespace == true ? " " : "")
    }

    private static func skippedLines(source: String, code: [String]) -> Set<Int> {
        var skip = Set<Int>()
        let original = source.components(separatedBy: "\n")
        // After "// MARK: - Previews" or "// MARK: - Fakes": preview and fake data to the end of the file.
        for (index, text) in original.enumerated() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("// MARK: - Previews") || t.hasPrefix("// MARK: - Fakes") {
                for l in (index + 1)...max(index + 1, original.count) { skip.insert(l) }
                break
            }
        }
        // #Preview { ... } blocks, by brace counting on the blanked code.
        var index = 0
        while index < code.count {
            if code[index].trimmingCharacters(in: .whitespaces).hasPrefix("#Preview") {
                var depth = 0
                var started = false
                var j = index
                while j < code.count {
                    let open = code[j].filter { $0 == "{" }.count
                    let close = code[j].filter { $0 == "}" }.count
                    if open > 0 { started = true }
                    depth += open - close
                    skip.insert(j + 1)
                    if started, depth <= 0 { break }
                    j += 1
                }
                index = j + 1
            } else {
                index += 1
            }
        }
        // #if DEBUG ... #endif (the DEBUG branch); `#if !DEBUG`'s #else branch.
        struct Block { var debugBranchSkipped: Bool; var negated: Bool; var inElse = false }
        var stack: [Block] = []
        for (idx, text) in code.enumerated() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if ") {
                let cond = t.dropFirst(4).trimmingCharacters(in: .whitespaces)
                stack.append(Block(debugBranchSkipped: cond == "DEBUG" || cond == "!DEBUG", negated: cond == "!DEBUG"))
            } else if t.hasPrefix("#else") || t.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1].inElse = true }
            } else if t.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            for block in stack where block.debugBranchSkipped {
                // DEBUG: skip the main branch. !DEBUG: skip the #else branch.
                if block.negated == block.inElse { skip.insert(idx + 1) }
            }
        }
        return skip
    }
}
