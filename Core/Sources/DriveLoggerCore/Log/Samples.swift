/// Three-axis reading in the device reference frame.
public struct Vector3: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)

    public var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }
}

/// Device attitude as a unit quaternion.
///
/// Stored as a quaternion rather than Euler angles: roll/pitch/yaw lose
/// uniqueness at gimbal lock, which a phone in a car windscreen mount reaches
/// routinely.
public struct Quaternion: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)
}

/// One fused device-motion sample.
///
/// Mirrors `CMDeviceMotion` so the app layer can copy fields across without
/// interpretation. Units match CoreMotion's: acceleration in g, rotation in
/// rad/s, magnetic field in microtesla.
public struct MotionSample: Hashable, Sendable, Codable {
    /// Acceleration with gravity removed, in g.
    public var userAcceleration: Vector3
    /// Gravity direction in the device frame, in g.
    public var gravity: Vector3
    /// Bias-corrected rotation rate, in rad/s.
    public var rotationRate: Vector3
    public var attitude: Quaternion
    /// Calibrated magnetic field in microtesla; nil until CoreMotion reports a
    /// usable calibration accuracy.
    public var magneticField: Vector3?

    public init(
        userAcceleration: Vector3,
        gravity: Vector3,
        rotationRate: Vector3,
        attitude: Quaternion,
        magneticField: Vector3? = nil
    ) {
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.attitude = attitude
        self.magneticField = magneticField
    }
}

/// One GNSS fix.
///
/// Accuracy and the `speed`/`course` fields keep CoreLocation's convention that
/// a negative value means "not available" rather than being clamped or dropped —
/// a fix with invalid course is still a useful position fix, and the
/// distinction matters when fitting a trajectory.
public struct LocationSample: Hashable, Sendable, Codable {
    /// Degrees, WGS 84.
    public var latitude: Double
    /// Degrees, WGS 84.
    public var longitude: Double
    /// Metres above mean sea level.
    public var altitude: Double
    /// Metres; negative means the position is invalid.
    public var horizontalAccuracy: Double
    /// Metres; negative means the altitude is invalid.
    public var verticalAccuracy: Double
    /// Metres per second; negative means unavailable.
    public var speed: Double
    /// Metres per second; negative means unavailable.
    public var speedAccuracy: Double
    /// Degrees clockwise from true north; negative means unavailable.
    public var course: Double
    /// Degrees; negative means unavailable.
    public var courseAccuracy: Double

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double,
        speedAccuracy: Double,
        course: Double,
        courseAccuracy: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
    }

    public var hasValidPosition: Bool { horizontalAccuracy >= 0 }
    public var hasValidSpeed: Bool { speed >= 0 && speedAccuracy >= 0 }
    public var hasValidCourse: Bool { course >= 0 && courseAccuracy >= 0 }
}

/// One decoded OBD reading.
public struct OBDSample: Hashable, Sendable, Codable {
    public var pid: OBDPID
    public var value: Double
    public var unit: OBDUnit
    /// The adapter's raw reply, kept so a decoding bug found later can be
    /// re-analysed against drives already recorded.
    public var raw: String?

    public init(pid: OBDPID, value: Double, unit: OBDUnit, raw: String? = nil) {
        self.pid = pid
        self.value = value
        self.unit = unit
        self.raw = raw
    }

    public init(measurement: OBDMeasurement, raw: String? = nil) {
        self.init(
            pid: measurement.pid,
            value: measurement.value,
            unit: measurement.unit,
            raw: raw
        )
    }
}
