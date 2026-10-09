import Foundation

/// The live app's navigation seed for a recording (N4 B).
///
/// Every recording gets its own seed, derived from its header, so a replay
/// of the recording can rebuild exactly the engine the driver saw
/// (`replay_nav --seed header`, `--as-live`). The seed is the 64-bit FNV-1a
/// hash of the UTF-8 bytes of `sessionID.uuidString` (the canonical
/// upper-case form a header encodes). `sessionID` is exact in the file,
/// unlike `startedAt`, whose ISO 8601 encoding drops the sub-second part.
public enum NavigationSeed {
    /// The seed of the recording with this header.
    public static func derive(header: LogHeader) -> UInt64 {
        derive(sessionID: header.sessionID)
    }

    /// The seed of the recording with this session ID.
    public static func derive(sessionID: UUID) -> UInt64 {
        fnv1a64(Array(sessionID.uuidString.utf8))
    }

    static let fnvOffsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    static let fnvPrime: UInt64 = 0x0000_0100_0000_01B3

    /// 64-bit FNV-1a over `bytes`.
    public static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash = fnvOffsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= fnvPrime
        }
        return hash
    }

    /// `value` as 16 lowercase hex digits.
    public static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}
