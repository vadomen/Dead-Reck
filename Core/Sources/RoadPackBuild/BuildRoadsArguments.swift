import DriveLoggerCore
import Foundation

/// The parts of `build_roads` argument handling that can go wrong on bad
/// input, in a library so `swift test` covers them; `main.swift` only maps
/// a refusal to its exit status (2, usage).
public enum BuildRoadsArguments {
    /// `--grid-bbox minLon,minLat,maxLon,maxLat` (degrees, either corner
    /// order) as the grid's south-west and north-east corners in E7, or
    /// why it is refused: exactly four finite numbers, |lat| ≤ 90 and
    /// |lon| ≤ 180 (R16.1-2). Out of range, a value would not fit the
    /// `Int32` E7 conversion and trap.
    public static func gridBox(_ text: String) -> Result<(southWest: RoadPoint, northEast: RoadPoint), Refusal> {
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let values = fields.compactMap(Double.init)
        guard fields.count == 4, values.count == 4 else {
            return .failure(Refusal("--grid-bbox: expected minLon,minLat,maxLon,maxLat, got \(text)"))
        }
        guard values.allSatisfy(\.isFinite) else { return .failure(Refusal("--grid-bbox: not a finite number in \(text)")) }
        let (lon0, lat0, lon1, lat1) = (values[0], values[1], values[2], values[3])
        guard abs(lat0) <= 90, abs(lat1) <= 90 else { return .failure(Refusal("--grid-bbox: latitude outside ±90° in \(text)")) }
        guard abs(lon0) <= 180, abs(lon1) <= 180 else { return .failure(Refusal("--grid-bbox: longitude outside ±180° in \(text)")) }
        let southWest = RoadPoint(latE7: Int32((min(lat0, lat1) * 1e7).rounded(.down)), lonE7: Int32((min(lon0, lon1) * 1e7).rounded(.down)))
        let northEast = RoadPoint(latE7: Int32((max(lat0, lat1) * 1e7).rounded(.up)), lonE7: Int32((max(lon0, lon1) * 1e7).rounded(.up)))
        return .success((southWest, northEast))
    }

    /// `--bench n`: a positive whole number of queries (R16.1-2: a
    /// negative count traps in `RoadPackBench`; 0 measures nothing).
    public static func benchQueries(_ text: String) -> Result<Int, Refusal> {
        guard let n = Int(text), n > 0 else { return .failure(Refusal("--bench: expected a positive number of queries, got \(text)")) }
        return .success(n)
    }

    /// `--info`: verify the pack (hash and structure), then, only if it
    /// verified, run the lookup bench (R16.2-1). The bench walks the
    /// pack's records unchecked, so on a pack that failed `verify()` (an
    /// edge of `pointCount` 0, say) it would trap instead of `build_roads`
    /// exiting 4.
    public static func inspect(_ pack: RoadPack, benchQueries: Int?) -> Inspection {
        var verifyError: Error?
        let elapsed = ContinuousClock().measure {
            do { try pack.verify() } catch { verifyError = error }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let bench = verifyError == nil ? benchQueries.map { RoadPackBench.run(pack: pack, queries: $0) } : nil
        return Inspection(verifyError: verifyError, verifySeconds: seconds, bench: bench)
    }

    public struct Inspection {
        /// nil: the pack verified.
        public var verifyError: Error?
        public var verifySeconds: Double
        /// nil without `--bench`, and whenever `verifyError` is set.
        public var bench: RoadPackBench.Report?
    }

    /// Why an argument is refused, for the usage error.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }
}
