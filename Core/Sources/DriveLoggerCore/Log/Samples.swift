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
    /// `CMMagneticFieldCalibrationAccuracy` raw value (-1 uncalibrated … 2
    /// high). Added in v2; absent in v1 recordings.
    public var magneticAccuracy: Int?

    public init(
        userAcceleration: Vector3,
        gravity: Vector3,
        rotationRate: Vector3,
        attitude: Quaternion,
        magneticField: Vector3? = nil,
        magneticAccuracy: Int? = nil
    ) {
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.attitude = attitude
        self.magneticField = magneticField
        self.magneticAccuracy = magneticAccuracy
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

    // v2 additions. In v2 the event's `t` is the fix time on the session clock,
    // i.e. `receivedT - ageS`; these fields keep the inputs to that conversion.

    /// When the app received the fix, on the session clock.
    public var receivedT: MonotonicTimestamp?
    /// `CLLocation.timestamp` verbatim, ISO 8601 with fractional seconds. Wall
    /// clock: for audit and offline re-derivation only.
    public var fixTime: String?
    /// Age of the fix at receipt, in seconds: wall clock at receipt minus
    /// `fixTime`. Both readings are taken together, so clock jumps cancel.
    public var ageS: Double?
    /// Metres above the WGS 84 ellipsoid.
    public var ellipsoidalAltitude: Double?
    /// `CLLocationSourceInformation.isSimulatedBySoftware`.
    public var simulated: Bool?
    /// `CLLocationSourceInformation.isProducedByAccessory`.
    public var accessory: Bool?

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double,
        speedAccuracy: Double,
        course: Double,
        courseAccuracy: Double,
        receivedT: MonotonicTimestamp? = nil,
        fixTime: String? = nil,
        ageS: Double? = nil,
        ellipsoidalAltitude: Double? = nil,
        simulated: Bool? = nil,
        accessory: Bool? = nil
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
        self.receivedT = receivedT
        self.fixTime = fixTime
        self.ageS = ageS
        self.ellipsoidalAltitude = ellipsoidalAltitude
        self.simulated = simulated
        self.accessory = accessory
    }

    public var hasValidPosition: Bool { horizontalAccuracy >= 0 }
    public var hasValidSpeed: Bool { speed >= 0 && speedAccuracy >= 0 }
    public var hasValidCourse: Bool { course >= 0 && courseAccuracy >= 0 }
}

/// One decoded OBD reading. The event's `t` is when the reply arrived.
public struct OBDSample: Hashable, Sendable, Codable {
    public var pid: OBDPID
    public var value: Double
    public var unit: OBDUnit
    /// The adapter's raw reply, kept so a decoding bug found later can be
    /// re-analysed against drives already recorded.
    ///
    /// v1 wrote header-off replies (`410D32`). v2 writes the full verbatim
    /// reply with headers and every answering ECU (`7E803410D32`), which is why
    /// the format version changed.
    public var raw: String?

    // v2 additions.

    /// When the request was written, on the session clock.
    public var requestT: MonotonicTimestamp?
    /// The command that produced this reply, e.g. `010D0C1`.
    public var command: String?
    /// CAN header of the answering ECU, e.g. `7E8`. Absent with headers off.
    public var ecu: String?
    /// Sequence number of the `elm` exchange this was decoded from.
    public var seq: Int?

    public init(
        pid: OBDPID,
        value: Double,
        unit: OBDUnit,
        raw: String? = nil,
        requestT: MonotonicTimestamp? = nil,
        command: String? = nil,
        ecu: String? = nil,
        seq: Int? = nil
    ) {
        self.pid = pid
        self.value = value
        self.unit = unit
        self.raw = raw
        self.requestT = requestT
        self.command = command
        self.ecu = ecu
        self.seq = seq
    }

    public init(
        measurement: OBDMeasurement,
        raw: String? = nil,
        requestT: MonotonicTimestamp? = nil,
        command: String? = nil,
        ecu: String? = nil,
        seq: Int? = nil
    ) {
        self.init(
            pid: measurement.pid,
            value: measurement.value,
            unit: measurement.unit,
            raw: raw,
            requestT: requestT,
            command: command,
            ecu: ecu,
            seq: seq
        )
    }
}
