/// Hex helpers for ELM327 traffic, which is ASCII hex end to end.
enum Hex {
    static func string(_ byte: UInt8) -> String {
        let digits = "0123456789ABCDEF"
        let high = digits[digits.index(digits.startIndex, offsetBy: Int(byte >> 4))]
        let low = digits[digits.index(digits.startIndex, offsetBy: Int(byte & 0x0F))]
        return String([high, low])
    }

    static func string(_ bytes: [UInt8]) -> String {
        bytes.map(string).joined()
    }

    /// Parses whitespace-tolerant ASCII hex. Adapters may be configured with
    /// `ATS1` (spaces between bytes) or `ATS0` (none), and some insert a stray
    /// space mid-line, so whitespace is stripped before pairing digits.
    static func bytes(in text: some StringProtocol) throws -> [UInt8] {
        let digits = String(text.filter { !$0.isWhitespace })
        guard !digits.isEmpty else { return [] }
        guard digits.count.isMultiple(of: 2) else {
            throw ELM327Error.malformedHex(String(text))
        }

        var result: [UInt8] = []
        result.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else {
                throw ELM327Error.malformedHex(String(text))
            }
            result.append(byte)
            index = next
        }
        return result
    }
}
