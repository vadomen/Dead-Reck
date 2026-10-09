import Foundation

/// Seedable pseudo-random generator for the navigation engine: xoshiro256**
/// seeded through SplitMix64.
///
/// The engine draws every random number from one of these, so the same seed,
/// input and configuration give bit-identical output on the same platform.
/// `SystemRandomNumberGenerator` would make replay results unrepeatable.
public struct NavigationRandom: RandomNumberGenerator, Hashable, Sendable {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64
    /// Second value of the last Box–Muller pair, not yet returned.
    private var spareGaussian: Double?

    public init(seed: UInt64) {
        var splitMix = seed
        s0 = Self.splitMix64(&splitMix)
        s1 = Self.splitMix64(&splitMix)
        s2 = Self.splitMix64(&splitMix)
        s3 = Self.splitMix64(&splitMix)
        // xoshiro's state must not be all zero; SplitMix64 never produces four
        // zeros in a row, but be explicit.
        if s0 | s1 | s2 | s3 == 0 { s0 = 0x9E37_79B9_7F4A_7C15 }
    }

    private static func splitMix64(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    public mutating func next() -> UInt64 {
        let result = Self.rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = Self.rotl(s3, 45)
        return result
    }

    /// Uniform in [0, 1), 53 bits.
    @inline(__always)
    public mutating func nextUniform() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// Standard normal, Box–Muller. Values come in pairs; the second of a
    /// pair is returned by the next call.
    public mutating func nextGaussian() -> Double {
        if let spare = spareGaussian {
            spareGaussian = nil
            return spare
        }
        let (a, b) = nextGaussianPair()
        spareGaussian = b
        return a
    }

    /// Two independent standard normals from one Box–Muller transform.
    @inline(__always)
    public mutating func nextGaussianPair() -> (Double, Double) {
        // 1 - u is in (0, 1], so the logarithm is finite.
        let u1 = 1 - nextUniform()
        let u2 = nextUniform()
        let radius = (-2 * Foundation.log(u1)).squareRoot()
        let angle = 2 * Double.pi * u2
        return (radius * Foundation.cos(angle), radius * Foundation.sin(angle))
    }
}
