/// Event payloads and header sections added in format v2.
///
/// These are on-disk types: every stored property name is a JSON key and part
/// of the format. Fields that carry an open-ended vocabulary (outcomes, phases,
/// state names, lifecycle events) are stored as `String` rather than as an enum,
/// so a value added by a later build still decodes instead of failing the line.
/// The enums that produce those strings live next to the code that writes them.

// MARK: - Header sections

/// The BLE adapter a recording was made through, as found by the most recent
/// successful initialisation.
public struct AdapterRecord: Hashable, Sendable, Codable {
    /// Advertised peripheral name, e.g. `IOS-Vlink`.
    public var name: String
    /// `CBPeripheral.identifier` as a UUID string. Stable per phone, not across
    /// phones.
    public var identifier: String
    /// The UART characteristic pair actually used.
    public var gatt: GATTSelection?
    /// Every service and characteristic discovered, for diagnosing clones that
    /// expose an unexpected layout.
    public var gattTable: [GATTServiceRecord]?
    /// `ATZ` banner, e.g. `ELM327 v2.1`.
    public var elmVersion: String?
    /// Raw `ATDPN` reply, e.g. `A6` (the `A` means auto-detected).
    public var protocolNumber: String?
    /// Parsed `ATRV` reading, in volts. The raw reply is in the `elm` row.
    public var voltage: Double?

    public init(
        name: String,
        identifier: String,
        gatt: GATTSelection? = nil,
        gattTable: [GATTServiceRecord]? = nil,
        elmVersion: String? = nil,
        protocolNumber: String? = nil,
        voltage: Double? = nil
    ) {
        self.name = name
        self.identifier = identifier
        self.gatt = gatt
        self.gattTable = gattTable
        self.elmVersion = elmVersion
        self.protocolNumber = protocolNumber
        self.voltage = voltage
    }

    enum CodingKeys: String, CodingKey {
        case name, identifier, gatt, gattTable, elmVersion, voltage
        case protocolNumber = "protocol"
    }
}

/// The characteristic pair a BLE transport selected for ELM327 traffic.
public struct GATTSelection: Hashable, Sendable, Codable {
    public var service: String
    public var notify: String
    public var write: String
    /// `withResponse` or `withoutResponse`.
    public var writeType: String
    /// `maximumWriteValueLength(for:)` for the chosen write type, in bytes.
    public var maxWriteLength: Int

    public init(service: String, notify: String, write: String, writeType: String, maxWriteLength: Int) {
        self.service = service
        self.notify = notify
        self.write = write
        self.writeType = writeType
        self.maxWriteLength = maxWriteLength
    }
}

public struct GATTServiceRecord: Hashable, Sendable, Codable {
    public var service: String
    public var characteristics: [GATTCharacteristicRecord]

    public init(service: String, characteristics: [GATTCharacteristicRecord]) {
        self.service = service
        self.characteristics = characteristics
    }
}

public struct GATTCharacteristicRecord: Hashable, Sendable, Codable {
    public var uuid: String
    /// CoreBluetooth property names, e.g. `notify`, `write`, `writeWithoutResponse`.
    public var properties: [String]

    public init(uuid: String, properties: [String]) {
        self.uuid = uuid
        self.properties = properties
    }
}

/// The OBD polling combination in use.
public struct PollingRecord: Hashable, Sendable, Codable {
    /// Exact poll command as sent, e.g. `010D0C1`.
    public var command: String
    /// PID numbers covered by `command`. Plain integers so a PID this build
    /// doesn't know still decodes.
    public var pids: [Int]
    public var multiPID: Bool
    /// Response-count suffix (`1` in `010D1`), absent when not used.
    public var responseCount: Int?
    /// `ATAT` level: 0, 1 or 2.
    public var adaptiveTiming: Int
    /// RPM is polled every Nth cycle when not combined into `command`.
    public var rpmEvery: Int
    /// Per-command timeout, in milliseconds.
    public var timeoutMs: Int

    public init(
        command: String,
        pids: [Int],
        multiPID: Bool,
        responseCount: Int? = nil,
        adaptiveTiming: Int,
        rpmEvery: Int,
        timeoutMs: Int
    ) {
        self.command = command
        self.pids = pids
        self.multiPID = multiPID
        self.responseCount = responseCount
        self.adaptiveTiming = adaptiveTiming
        self.rpmEvery = rpmEvery
        self.timeoutMs = timeoutMs
    }
}

/// Requested sensor configuration. What was asked for, not what was achieved —
/// achieved rates are in `stats` rows.
public struct SensorConfigRecord: Hashable, Sendable, Codable {
    public var deviceMotionHz: Double
    public var accelerometerHz: Double
    public var gyroHz: Double
    public var magnetometerHz: Double
    /// `CMAttitudeReferenceFrame` name, e.g. `xArbitraryZVertical`.
    public var referenceFrame: String
    public var altimeter: Bool

    public init(
        deviceMotionHz: Double,
        accelerometerHz: Double,
        gyroHz: Double,
        magnetometerHz: Double,
        referenceFrame: String,
        altimeter: Bool
    ) {
        self.deviceMotionHz = deviceMotionHz
        self.accelerometerHz = accelerometerHz
        self.gyroHz = gyroHz
        self.magnetometerHz = magnetometerHz
        self.referenceFrame = referenceFrame
        self.altimeter = altimeter
    }
}

// MARK: - Event payloads

/// `baro`: one `CMAltitudeData` reading.
public struct BarometerSample: Hashable, Sendable, Codable {
    /// Kilopascals.
    public var pressureKPa: Double
    /// Metres, relative to the first reading of the altimeter session.
    public var relativeAltitude: Double

    public init(pressureKPa: Double, relativeAltitude: Double) {
        self.pressureKPa = pressureKPa
        self.relativeAltitude = relativeAltitude
    }
}

/// `elm`: one command/reply exchange with the adapter, verbatim.
public struct ELMTrafficSample: Hashable, Sendable, Codable {
    /// Exchange sequence number, unique within a recording. `obd` rows decoded
    /// from this exchange carry the same value.
    public var seq: Int
    /// `init`, `probe`, `poll`, `manual` or `keepalive`.
    public var phase: String
    /// Command as written, without the carriage return.
    public var tx: String
    /// When the write was issued.
    public var requestT: MonotonicTimestamp
    /// Reply as received, minus the `>` prompt. Absent on timeout or rejection.
    public var rx: String?
    /// See `docs/LOG_FORMAT.md` for the vocabulary.
    public var outcome: String

    public init(
        seq: Int,
        phase: String,
        tx: String,
        requestT: MonotonicTimestamp,
        rx: String? = nil,
        outcome: String
    ) {
        self.seq = seq
        self.phase = phase
        self.tx = tx
        self.requestT = requestT
        self.rx = rx
        self.outcome = outcome
    }
}

/// `adapter`: the result of a successful (re-)initialisation.
public struct AdapterEventSample: Hashable, Sendable, Codable {
    public var adapter: AdapterRecord
    public var polling: PollingRecord?

    public init(adapter: AdapterRecord, polling: PollingRecord? = nil) {
        self.adapter = adapter
        self.polling = polling
    }
}

/// `link`: a state transition of the BLE link or the ELM session.
public struct LinkSample: Hashable, Sendable, Codable {
    /// `ble` or `elm`.
    public var layer: String
    public var from: String
    public var to: String
    public var reason: String?

    public init(layer: String, from: String, to: String, reason: String? = nil) {
        self.layer = layer
        self.from = from
        self.to = to
        self.reason = reason
    }

    /// `layer` vocabulary. Raw values are on-disk strings: never rename them.
    public enum Layer: String, Hashable, Sendable, CaseIterable {
        case ble
        case elm
    }

    /// BLE link states written with `layer: ble`. The ELM states are
    /// `ELMState`. Raw values are on-disk strings: never rename them.
    public enum BLEState: String, Hashable, Sendable, CaseIterable {
        /// Bluetooth off, unauthorised or unsupported; `reason` says which.
        case unavailable
        /// Powered on, not connected, not scanning.
        case idle
        case scanning
        case connecting
        /// Connected, discovering services and characteristics.
        case discovering
        /// UART pair selected, notifications enabled; the ELM session runs.
        case connected
        /// Link lost; `reason` carries the CoreBluetooth error if any.
        case disconnected
        /// Waiting to retry a connection after a drop.
        case reconnecting
        /// Relaunched by the system with a restored peripheral.
        case restoring
    }
}

/// `lifecycle`: something that happened to the recording or the app.
public struct LifecycleSample: Hashable, Sendable, Codable {
    /// Raw value of `LifecycleSample.Event`, or a newer build's value.
    public var event: String
    public var detail: String?

    public init(event: String, detail: String? = nil) {
        self.event = event
        self.detail = detail
    }

    public init(_ event: Event, detail: String? = nil) {
        self.init(event: event.rawValue, detail: detail)
    }

    /// Lifecycle vocabulary. Raw values are on-disk strings: never rename them.
    public enum Event: String, Hashable, Sendable, CaseIterable {
        case start
        case stop
        case pause
        case resume
        case background
        case foreground
        case calibrationStart
        case calibrationEnd
        case error
        case memoryWarning
        case thermalState
        case protectedDataUnavailable
    }
}

/// `stats`: health of the recording over one window, written every 10 s.
///
/// Computed live because it describes the recorder itself — queue depth and
/// drops cannot be reconstructed from the file afterwards.
public struct StatsSample: Hashable, Sendable, Codable {
    /// Window length, in seconds.
    public var windowS: Double
    /// Events written in the window, by `kind`.
    public var counts: [String: Int]
    /// Successful OBD exchanges per second.
    public var obdHz: Double
    /// `motion` events per second.
    public var motionHz: Double
    /// Inter-sample intervals over 50 ms, by kind (`motion`, `accel`, `gyro`).
    public var gaps: [String: Int]
    /// Longest inter-sample interval, in milliseconds, by kind.
    public var maxGapMs: [String: Double]
    /// ELM exchanges that timed out in the window.
    public var timeouts: Int
    /// Highest writer queue depth seen in the window, in events.
    public var queueDepthMax: Int
    /// Events dropped in the window. Expected to be zero, always.
    public var dropped: Int
    /// Compressed bytes written to the file so far.
    public var bytesWritten: Int

    public init(
        windowS: Double,
        counts: [String: Int],
        obdHz: Double,
        motionHz: Double,
        gaps: [String: Int],
        maxGapMs: [String: Double],
        timeouts: Int,
        queueDepthMax: Int,
        dropped: Int,
        bytesWritten: Int
    ) {
        self.windowS = windowS
        self.counts = counts
        self.obdHz = obdHz
        self.motionHz = motionHz
        self.gaps = gaps
        self.maxGapMs = maxGapMs
        self.timeouts = timeouts
        self.queueDepthMax = queueDepthMax
        self.dropped = dropped
        self.bytesWritten = bytesWritten
    }
}
