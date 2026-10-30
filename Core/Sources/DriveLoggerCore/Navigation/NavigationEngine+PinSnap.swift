import Foundation

// Read-only accessors for snapping a manual fix to the road (`PinSnap`,
// prompt 46). Nothing here changes the engine's state or draws a random
// number: the engine's output is the same whether or not they are called.

extension NavigationEngine {
    /// The particle cloud at the last step, geodetic, for `PinSnap`'s cloud
    /// tie-break; nil before initialisation. O(N): one tangent-plane
    /// inversion per particle (2000 at the defaults).
    public func pinSnapCloud() -> [PinSnap.Particle]? {
        guard let plane = tangentPlane else { return nil }
        var out: [PinSnap.Particle] = []
        out.reserveCapacity(east.count)
        for i in east.indices {
            let g = plane.geodetic(east: east[i], north: north[i])
            out.append(PinSnap.Particle(latitude: g.latitude, longitude: g.longitude,
                                        headingRad: heading[i], weight: weight[i]))
        }
        return out
    }

    /// Snaps a tap with the engine's own road network (`roadNetwork`, nil
    /// without roads → `.noNetwork`) and cloud (`pinSnapCloud()`).
    public func snapPin(
        latitude: Double, longitude: Double, mapSpanM: Double?, viewportHeightPt: Double,
        parameters: PinSnap.Parameters = PinSnap.Parameters()
    ) -> PinSnap.Outcome {
        let network = roadNetwork
        return PinSnap.snap(
            latitude: latitude, longitude: longitude, mapSpanM: mapSpanM, viewportHeightPt: viewportHeightPt,
            network: network, cloud: network == nil ? nil : pinSnapCloud(), parameters: parameters
        )
    }
}

extension LiveNavigationRun {
    /// `engine.snapPin(...)`: the live run's network and cloud as of its
    /// latest step.
    public func snapPin(
        latitude: Double, longitude: Double, mapSpanM: Double?, viewportHeightPt: Double,
        parameters: PinSnap.Parameters = PinSnap.Parameters()
    ) -> PinSnap.Outcome {
        engine.snapPin(latitude: latitude, longitude: longitude, mapSpanM: mapSpanM,
                       viewportHeightPt: viewportHeightPt, parameters: parameters)
    }
}
