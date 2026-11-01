import Foundation

// UX-7: what the map shows in a no-OBD Navigate run, beyond the status card
// (`NavigateStatus.noOBD`): the speed estimate and the uncertain treatment of
// the dot and ellipse. Pure values, in the style of `MapSpeedRule`.

struct NoOBDDisplay: Equatable, Sendable {
    /// 120 s without an accepted fix or pin (`NoOBDNavigationStatus.positionUncertain`):
    /// dimmed dot, dashed ellipse, no speed estimate.
    var uncertain: Bool
    /// The engine's speed estimate, km/h; nil until it has one.
    var estimatedKmh: Double?

    /// nil unless `navigate` is a no-OBD run. `status` is nil until the
    /// service's first reading: a run with nothing uncertain and no estimate.
    static func make(navigate: NavigateState, status: NoOBDNavigationStatus?) -> NoOBDDisplay? {
        guard navigate.isNoOBD else { return nil }
        return NoOBDDisplay(
            uncertain: status?.positionUncertain ?? false, estimatedKmh: status?.estimatedSpeedKmh)
    }

    /// The HUD speed: a measurement always wins (`base` from `MapSpeedRule`: a
    /// fresh GPS speed; in a no-OBD run never OBD). With none, the engine's
    /// estimate as `.estimated` (whole km/h, never negative), hidden while the
    /// position is uncertain or the engine has no finite estimate.
    func speed(base: MapSpeedReadout) -> MapSpeedReadout {
        guard base.source == .none, !uncertain, let estimatedKmh, estimatedKmh.isFinite else { return base }
        return MapSpeedReadout(source: .estimated, kmh: Int(max(0, estimatedKmh).rounded()), quality: .unknown)
    }
}

extension MapSpeedReadout {
    /// The speed the camera's zoom may use: measured, never an estimate
    /// ("camera framing rules unchanged" in a no-OBD run).
    var measuredKmh: Int? { source == .estimated ? nil : kmh }
}
