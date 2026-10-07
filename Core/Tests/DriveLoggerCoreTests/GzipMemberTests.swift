import Foundation
import Testing

@testable import DriveLoggerCore

/// Helpers that run the system gzip tools on a scratch file. macOS only — the
/// Core suite runs on the Mac.
enum SystemGzip {
    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting so a large output can't fill the pipe and stall.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    /// `gzip -t <file>`: exit status 0 when every member is intact.
    static func test(_ url: URL) throws -> Result {
        try run("/usr/bin/gzip", ["-t", url.path])
    }

    /// `gunzip -c <file>`: the concatenated payload of every member.
    static func decompress(_ url: URL) throws -> Result {
        try run("/usr/bin/gunzip", ["-c", url.path])
    }
}

/// A scratch directory under the system temporary directory, removed by the
/// caller. Recordings never land in the repository tree.
struct ScratchDirectory {
    let url: URL

    init(_ label: String = #function) throws {
        let safe = label.filter { $0.isLetter || $0.isNumber }
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivelogger-\(safe)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("CRC-32")
struct CRC32Tests {
    @Test("Standard check value for \"123456789\"")
    func checkValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("Empty input is zero")
    func empty() {
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test("Incremental updates equal a one-shot checksum")
    func incremental() {
        let whole = Data("The quick brown fox jumps over the lazy dog".utf8)
        #expect(CRC32.checksum(whole) == 0x414F_A339)
        var crc = CRC32()
        crc.update(whole.prefix(10))
        crc.update(whole.dropFirst(10))
        #expect(crc.value == 0x414F_A339)
    }
}

@Suite("Gzip member")
struct GzipMemberTests {
    static let payload = Data(
        (0..<500).map { #"{"data":{"x":\#($0)},"kind":"accel","t":\#($0 * 10_000_000)}"# }
            .joined(separator: "\n")
            .appending("\n")
            .utf8
    )

    @Test("Header: gzip magic, deflate, FEXTRA only, no timestamp")
    func headerLayout() throws {
        let member = try GzipMember.make(Self.payload)
        #expect(member[0] == 0x1F)
        #expect(member[1] == 0x8B)
        #expect(member[2] == 8)            // CM = deflate
        #expect(member[3] == 0x04)         // FLG = FEXTRA
        #expect(member[4..<8].allSatisfy { $0 == 0 })   // MTIME 0: no wall clock
        #expect(member[9] == 255)          // OS unknown
        // XLEN = 8: one subfield, "DL", LEN 4, UInt32 compressed length.
        #expect(member[10] == 8 && member[11] == 0)
        #expect(member[12] == UInt8(ascii: "D") && member[13] == UInt8(ascii: "L"))
        #expect(member[14] == 4 && member[15] == 0)
        let compressedLength = Int(member[16]) | Int(member[17]) << 8 | Int(member[18]) << 16 | Int(member[19]) << 24
        #expect(member.count == GzipMember.headerLength + compressedLength + GzipMember.trailerLength)
    }

    @Test("Trailer carries CRC-32 and ISIZE of the payload")
    func trailer() throws {
        let member = try GzipMember.make(Self.payload)
        let trailer = Array(member.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        #expect(crc == CRC32.checksum(Self.payload))
        #expect(size == UInt32(Self.payload.count))
    }

    @Test("Compresses: text payload shrinks")
    func compresses() throws {
        let member = try GzipMember.make(Self.payload)
        #expect(member.count < Self.payload.count / 3)
    }

    @Test("Our own parser finds the member boundary and decodes it")
    func parsesOwnMember() throws {
        let member = try GzipMember.make(Self.payload)
        guard case .complete(let header) = GzipMember.parseHeader(member) else {
            Issue.record("header did not parse")
            return
        }
        #expect(header.headerLength == GzipMember.headerLength)
        #expect(header.totalLength == member.count)
        let decoded = try GzipMember.decode(member)
        #expect(decoded == Self.payload)
    }

    @Test("A header cut short asks for more bytes rather than failing")
    func shortHeaderNeedsMore() throws {
        let member = try GzipMember.make(Self.payload)
        for cut in 0..<GzipMember.headerLength {
            #expect(GzipMember.parseHeader(member.prefix(cut)) == .needMoreBytes, "cut \(cut)")
        }
    }

    @Test("Bytes that are not a gzip member are rejected")
    func rejectsGarbage() {
        #expect(GzipMember.parseHeader(Data(repeating: 0, count: 32)) == .invalid)
        #expect(GzipMember.parseHeader(Data("{\"formatVersion\":2}\n".utf8)) == .invalid)
    }

    @Test("A flipped payload bit fails the CRC check")
    func detectsCorruption() throws {
        var member = try GzipMember.make(Data("hello hello hello\n".utf8))
        // Corrupt the stored CRC itself so decompression still succeeds.
        let crcIndex = member.count - 8
        member[crcIndex] ^= 0x01
        #expect(throws: GzipMemberError.self) {
            try GzipMember.decode(member)
        }
    }

    #if os(macOS)
    // PLAN §3.5: "Verify in M1 (test): output passes gzip -t and round-trips
    // through /usr/bin/gunzip." This is also the check that
    // `NSData.compressed(using: .zlib)` really produces raw DEFLATE: a zlib
    // wrapper (78 9C …) inside a gzip member would fail `gzip -t`.
    @Test("One member passes gzip -t and gunzips to the payload")
    func systemGzipAcceptsMember() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let file = scratch.file("one.gz")
        try GzipMember.make(Self.payload).write(to: file)

        let check = try SystemGzip.test(file)
        #expect(check.status == 0, "gzip -t: \(check.stderr)")
        let output = try SystemGzip.decompress(file)
        #expect(output.status == 0, "gunzip: \(output.stderr)")
        #expect(output.stdout == Self.payload)
    }

    @Test("Concatenated members are one gzip stream to gunzip")
    func systemGzipAcceptsConcatenation() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let file = scratch.file("many.gz")
        let parts = (0..<5).map { Data("member \($0)\n".utf8) + Self.payload }
        var bytes = Data()
        for part in parts {
            bytes.append(try GzipMember.make(part))
        }
        try bytes.write(to: file)

        #expect(try SystemGzip.test(file).status == 0)
        let output = try SystemGzip.decompress(file)
        #expect(output.status == 0)
        #expect(output.stdout == parts.reduce(Data(), +))
    }

    @Test("Raw DEFLATE: the compressed body is not zlib-wrapped")
    func bodyIsRawDeflate() throws {
        let member = try GzipMember.make(Self.payload)
        let body = member[GzipMember.headerLength...]
        // A zlib stream starts with CMF 0x78; raw DEFLATE from this payload
        // starts with a block header whose low bits are BFINAL/BTYPE.
        #expect(body.first != 0x78)
    }
    #endif
}
