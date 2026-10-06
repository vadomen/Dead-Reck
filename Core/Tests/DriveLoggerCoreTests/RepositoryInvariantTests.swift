import Foundation
import Testing

/// Source-level checks for invariants the type system can't enforce.
///
/// Reads the repository through `#filePath`, so it runs on the Mac with
/// `swift test` like the rest of Core's suite. It inspects App sources as
/// text; Core still imports nothing from the app.
@Suite("Repository invariants")
struct RepositoryInvariantTests {
    /// `.../Core/Tests/DriveLoggerCoreTests/<this file>` → repository root.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func swiftFiles(under relativePath: String) throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(relativePath)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    // ValidatedELMCommand can only come from ELMCommandPolicy, but App code
    // holding the CBPeripheral could still write to it directly and bypass
    // the read-only guard. Only BLETransport.send may write.
    @Test("Only BLETransport writes to the adapter's characteristic")
    func onlyBLETransportWritesToPeripheral() throws {
        let files = try Self.swiftFiles(under: "App/Sources")
        #expect(!files.isEmpty, "App/Sources not found from \(Self.repositoryRoot.path)")

        for file in files where file.lastPathComponent != "BLETransport.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !text.contains("writeValue("),
                "\(file.lastPathComponent) calls writeValue; only BLETransport.send may write to the adapter"
            )
        }
    }
}
