import Foundation

// gzip without a dependency (docs/PLAN.md §3.5). Foundation has no streaming
// gzip, but `NSData.compressed(using: .zlib)` produces raw DEFLATE (RFC 1951,
// no zlib header) — verified by `GzipMemberTests` against `/usr/bin/gzip -t`
// and `/usr/bin/gunzip`. Each flush becomes one independent gzip member
// (RFC 1952); concatenated members are a valid gzip stream for every standard
// tool.

/// CRC-32 (IEEE 802.3, reflected polynomial `0xEDB88320`), as gzip uses it.
/// Table-driven, one byte per step.
struct CRC32: Sendable {
    private(set) var value: UInt32 = 0

    init() {}

    mutating func update(_ bytes: some DataProtocol) {
        var crc = ~value
        for region in bytes.regions {
            region.withUnsafeBytes { raw in
                for byte in raw {
                    crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        value = ~crc
    }

    static func checksum(_ bytes: some DataProtocol) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }
}

enum GzipMemberError: Error, Hashable, Sendable {
    case compressionFailed(String)
    case decompressionFailed(String)
    case notAMember
    case missingLengthField
    case truncated
    case crcMismatch(expected: UInt32, actual: UInt32)
    case sizeMismatch(expected: UInt32, actual: UInt32)
}

/// One gzip member as DriveLogger writes it:
///
/// ```
/// offset size  field
///      0    2  ID1 ID2   1F 8B
///      2    1  CM        08 (deflate)
///      3    1  FLG       04 (FEXTRA only)
///      4    4  MTIME     00 00 00 00 (no wall clock in members)
///      8    1  XFL       00
///      9    1  OS        FF (unknown)
///     10    2  XLEN      08 00
///     12    2  SI1 SI2   'D' 'L'
///     14    2  LEN       04 00
///     16    4  CLEN      UInt32 LE: length of the DEFLATE data that follows
///     20 CLEN  DEFLATE   raw DEFLATE (NSData .zlib)
///      …    4  CRC32     of the uncompressed payload, LE
///      …    4  ISIZE     uncompressed length mod 2^32, LE
/// ```
///
/// The `DL` subfield plays the role of BGZF's `BC`/`BSIZE`, widened to 32
/// bits because a member written after a long background stall can exceed
/// 64 KiB. It lets a reader step from member to member without a streaming
/// inflater, and lets it tell a complete member from a truncated one.
enum GzipMember {
    /// Bytes before the DEFLATE data in a member we write.
    static let headerLength = 20
    /// CRC32 + ISIZE.
    static let trailerLength = 8
    static let subfieldID: (UInt8, UInt8) = (UInt8(ascii: "D"), UInt8(ascii: "L"))

    /// Wraps `payload` (uncompressed bytes) in one member.
    static func make(_ payload: Data) throws(GzipMemberError) -> Data {
        let deflated: Data
        do {
            deflated = try (payload as NSData).compressed(using: .zlib) as Data
        } catch {
            throw .compressionFailed(String(describing: error))
        }
        guard deflated.count <= Int(UInt32.max) else {
            throw .compressionFailed("member of \(deflated.count) bytes exceeds the 32-bit length field")
        }

        var member = Data(capacity: headerLength + deflated.count + trailerLength)
        member.append(contentsOf: [0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0x00, 0xFF])
        member.append(contentsOf: [8, 0, subfieldID.0, subfieldID.1, 4, 0])
        member.appendLittleEndian(UInt32(deflated.count))
        member.append(deflated)
        member.appendLittleEndian(CRC32.checksum(payload))
        member.appendLittleEndian(UInt32(truncatingIfNeeded: payload.count))
        return member
    }

    struct Header: Hashable, Sendable {
        /// Bytes from the start of the member to the first DEFLATE byte.
        var headerLength: Int
        var compressedLength: Int
        /// Whole member, header through ISIZE.
        var totalLength: Int { headerLength + compressedLength + GzipMember.trailerLength }
    }

    enum HeaderParse: Hashable, Sendable {
        case complete(Header)
        /// `bytes` is a valid prefix of a member header; more bytes are needed.
        case needMoreBytes
        /// Not a gzip member header.
        case invalid
        /// A gzip member, but without our `DL` length subfield — written by
        /// another tool. Readable with `gunzip`, not sliceable by us.
        case foreign
    }

    /// Parses a member header at the start of `bytes`. Handles every RFC 1952
    /// header flag so a valid member is never misread, but needs the `DL`
    /// subfield to know where the member ends.
    static func parseHeader(_ bytes: some DataProtocol) -> HeaderParse {
        let b = Array(bytes.prefix(65_600))  // a header can't be longer than ~64 KiB + names
        func need(_ n: Int) -> Bool { b.count >= n }

        // Fixed part, checked byte by byte so a short prefix is judged on what
        // it has.
        let expected: [UInt8] = [0x1F, 0x8B, 0x08]
        for (index, byte) in expected.enumerated() {
            guard need(index + 1) else { return .needMoreBytes }
            guard b[index] == byte else { return .invalid }
        }
        guard need(4) else { return .needMoreBytes }
        let flags = b[3]
        guard flags & 0xE0 == 0 else { return .invalid }  // reserved bits
        guard need(10) else { return .needMoreBytes }
        var offset = 10

        var compressedLength: Int?
        if flags & 0x04 != 0 {
            guard need(offset + 2) else { return .needMoreBytes }
            let xlen = Int(b[offset]) | Int(b[offset + 1]) << 8
            offset += 2
            guard need(offset + xlen) else { return .needMoreBytes }
            var sub = offset
            let end = offset + xlen
            while sub + 4 <= end {
                let length = Int(b[sub + 2]) | Int(b[sub + 3]) << 8
                if b[sub] == subfieldID.0, b[sub + 1] == subfieldID.1, length == 4, sub + 8 <= end {
                    compressedLength = Int(b[sub + 4]) | Int(b[sub + 5]) << 8
                        | Int(b[sub + 6]) << 16 | Int(b[sub + 7]) << 24
                }
                sub += 4 + length
            }
            guard sub == end else { return .invalid }  // subfields must tile XLEN
            offset = end
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT
            guard let terminator = b[offset...].firstIndex(of: 0) else {
                return b.count < 65_600 ? .needMoreBytes : .invalid
            }
            offset = terminator + 1
        }
        if flags & 0x02 != 0 {  // FHCRC
            offset += 2
            guard need(offset) else { return .needMoreBytes }
        }
        guard let compressedLength else { return .foreign }
        return .complete(Header(headerLength: offset, compressedLength: compressedLength))
    }

    /// Decompresses one complete member (exactly its bytes) and verifies CRC
    /// and ISIZE — unless `verifyingChecksums` is false, which only the
    /// reader's salvage of a damaged header member uses.
    static func decode(_ member: some DataProtocol, verifyingChecksums: Bool = true) throws(GzipMemberError) -> Data {
        let bytes = Data(member)
        guard case .complete(let header) = parseHeader(bytes) else { throw .notAMember }
        guard bytes.count >= header.totalLength else { throw .truncated }
        let bodyStart = header.headerLength
        let bodyEnd = bodyStart + header.compressedLength
        let body = bytes.subdata(in: bodyStart..<bodyEnd)

        let payload: Data
        do {
            payload = try (body as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw .decompressionFailed(String(describing: error))
        }
        guard verifyingChecksums else { return payload }
        let storedCRC = bytes.readLittleEndianUInt32(at: bodyEnd)
        let storedSize = bytes.readLittleEndianUInt32(at: bodyEnd + 4)
        let actualCRC = CRC32.checksum(payload)
        guard storedCRC == actualCRC else { throw .crcMismatch(expected: storedCRC, actual: actualCRC) }
        let actualSize = UInt32(truncatingIfNeeded: payload.count)
        guard storedSize == actualSize else { throw .sizeMismatch(expected: storedSize, actual: actualSize) }
        return payload
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}
