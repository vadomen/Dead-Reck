import Foundation

/// One CSV layout per event kind, for analysis in Python/pandas
/// (`inspect_log --csv <dir>`).
///
/// Lossless by design: `t` and every `…T` column are integer nanoseconds on
/// the session clock, exactly as in the file; doubles use Swift's shortest
/// round-trip representation; absent optional fields are empty cells (never
/// 0); strings are verbatim, quoted RFC 4180-style when they contain a comma,
/// quote, CR or LF (ELM replies contain CRs). Nested values that have no
/// fixed columns (`stats.counts`, unknown kinds' `data`) are compact JSON.
public enum RecordingCSV {
    /// Column names for `kind`. Unknown kinds get `t,data`.
    public static func columns(for kind: String) -> [String] {
        switch LogEventKind(rawValue: kind) {
        case .motion:
            ["t",
             "userAccelerationX", "userAccelerationY", "userAccelerationZ",
             "gravityX", "gravityY", "gravityZ",
             "rotationRateX", "rotationRateY", "rotationRateZ",
             "attitudeX", "attitudeY", "attitudeZ", "attitudeW",
             "magneticFieldX", "magneticFieldY", "magneticFieldZ", "magneticAccuracy"]
        case .location:
            ["t", "latitude", "longitude", "altitude", "horizontalAccuracy", "verticalAccuracy",
             "speed", "speedAccuracy", "course", "courseAccuracy",
             "receivedT", "fixTime", "ageS", "ellipsoidalAltitude", "simulated", "accessory"]
        case .obd:
            ["t", "pid", "value", "unit", "raw", "requestT", "command", "ecu", "seq"]
        case .marker:
            ["t", "text"]
        case .accelerometer, .gyroscope, .magnetometer:
            ["t", "x", "y", "z"]
        case .barometer:
            ["t", "pressureKPa", "relativeAltitude"]
        case .elm:
            ["t", "seq", "phase", "tx", "requestT", "rx", "outcome"]
        case .adapter:
            ["t", "name", "identifier", "elmVersion", "protocol", "voltage",
             "gattService", "gattNotify", "gattWrite", "gattWriteType", "gattMaxWriteLength",
             "command", "pids", "multiPID", "responseCount", "adaptiveTiming", "rpmEvery", "timeoutMs",
             "requestHeader"]
        case .link:
            ["t", "layer", "from", "to", "reason"]
        case .lifecycle:
            ["t", "event", "detail"]
        case .stats:
            ["t", "windowS", "obdHz", "motionHz", "timeouts", "queueDepthMax", "dropped", "bytesWritten",
             "gapsMotion", "gapsAccel", "gapsGyro", "maxGapMsMotion", "maxGapMsAccel", "maxGapMsGyro", "counts"]
        case .manualFix:
            ["t", "latitude", "longitude", "pressedT", "mapSpanM", "obdSpeedKmh", "obdSpeedT",
             "gpsSpeedKmh", "speedSource", "gateSpeedKmh", "note"]
        case nil:
            ["t", "data"]
        }
    }

    /// Cell values for `event`, matching `columns(for: event.payload.kind)`.
    public static func values(for event: LogEvent) -> [String] {
        let t = String(event.timestamp.nanoseconds)
        switch event.payload {
        case .motion(let m):
            return [t] + v(m.userAcceleration) + v(m.gravity) + v(m.rotationRate)
                + [d(m.attitude.x), d(m.attitude.y), d(m.attitude.z), d(m.attitude.w)]
                + (m.magneticField.map(v) ?? ["", "", ""]) + [i(m.magneticAccuracy)]
        case .location(let l):
            return [t, d(l.latitude), d(l.longitude), d(l.altitude), d(l.horizontalAccuracy), d(l.verticalAccuracy),
                    d(l.speed), d(l.speedAccuracy), d(l.course), d(l.courseAccuracy),
                    ts(l.receivedT), l.fixTime ?? "", d(l.ageS), d(l.ellipsoidalAltitude), b(l.simulated), b(l.accessory)]
        case .obd(let o):
            return [t, String(o.pid.rawValue), d(o.value), o.unit.rawValue, o.raw ?? "",
                    ts(o.requestT), o.command ?? "", o.ecu ?? "", i(o.seq)]
        case .marker(let text):
            return [t, text]
        case .accelerometer(let vector), .gyroscope(let vector), .magnetometer(let vector):
            return [t] + v(vector)
        case .barometer(let sample):
            return [t, d(sample.pressureKPa), d(sample.relativeAltitude)]
        case .elm(let e):
            return [t, String(e.seq), e.phase, e.tx, ts(e.requestT), e.rx ?? "", e.outcome]
        case .adapter(let sample):
            let a = sample.adapter
            let p = sample.polling
            return [t, a.name, a.identifier, a.elmVersion ?? "", a.protocolNumber ?? "", d(a.voltage),
                    a.gatt?.service ?? "", a.gatt?.notify ?? "", a.gatt?.write ?? "", a.gatt?.writeType ?? "",
                    i(a.gatt?.maxWriteLength),
                    p?.command ?? "", p.map { $0.pids.map(String.init).joined(separator: ";") } ?? "",
                    b(p?.multiPID), i(p?.responseCount), i(p?.adaptiveTiming), i(p?.rpmEvery), i(p?.timeoutMs),
                    p?.requestHeader ?? ""]
        case .link(let l):
            return [t, l.layer, l.from, l.to, l.reason ?? ""]
        case .lifecycle(let l):
            return [t, l.event, l.detail ?? ""]
        case .stats(let s):
            return [t, d(s.windowS), d(s.obdHz), d(s.motionHz), String(s.timeouts), String(s.queueDepthMax),
                    String(s.dropped), String(s.bytesWritten),
                    i(s.gaps["motion"]), i(s.gaps["accel"]), i(s.gaps["gyro"]),
                    d(s.maxGapMs["motion"]), d(s.maxGapMs["accel"]), d(s.maxGapMs["gyro"]),
                    json(JSONValue.object(s.counts.mapValues { .int(Int64($0)) }))]
        case .manualFix(let f):
            return [t, d(f.latitude), d(f.longitude), ts(f.pressedT), d(f.mapSpanM), d(f.obdSpeedKmh), ts(f.obdSpeedT),
                    d(f.gpsSpeedKmh), f.speedSource, d(f.gateSpeedKmh), f.note ?? ""]
        case .unrecognized(_, let data):
            return [t, data.map(json) ?? ""]
        }
    }

    /// One CSV record, newline-terminated.
    public static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\n"
    }

    /// File name for a kind's CSV: letters, digits, `-` and `_` only.
    public static func fileName(for kind: String) -> String {
        let safe = String(kind.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_"
                ? Character(scalar) : "_"
        })
        return (safe.isEmpty ? "_" : safe) + ".csv"
    }

    static func escape(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func d(_ value: Double?) -> String { value.map { String(describing: $0) } ?? "" }
    private static func i(_ value: Int?) -> String { value.map(String.init) ?? "" }
    private static func b(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "" }
    private static func ts(_ value: MonotonicTimestamp?) -> String { value.map { String($0.nanoseconds) } ?? "" }
    private static func v(_ vector: Vector3) -> [String] { [d(vector.x), d(vector.y), d(vector.z)] }

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// Writes one CSV file per kind into a directory, streaming: rows are
/// buffered per kind and appended in 1 MiB batches. Existing files with the
/// same names are replaced. Not `Sendable`; use from one thread.
public final class RecordingCSVExporter {
    public let directory: URL
    private var outputs: [String: Output] = [:]

    private final class Output {
        let handle: FileHandle
        var buffer = Data()
        var rows = 0

        init(handle: FileHandle) {
            self.handle = handle
        }
    }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func write(_ event: LogEvent) throws {
        let kind = event.payload.kind
        let output = try outputs[kind] ?? open(kind)
        output.buffer.append(contentsOf: RecordingCSV.line(RecordingCSV.values(for: event)).utf8)
        output.rows += 1
        if output.buffer.count >= 1 << 20 {
            try output.handle.write(contentsOf: output.buffer)
            output.buffer.removeAll(keepingCapacity: true)
        }
    }

    /// Flushes and closes every file. Returns data rows written per kind.
    @discardableResult
    public func finish() throws -> [String: Int] {
        var rows: [String: Int] = [:]
        for (kind, output) in outputs {
            try output.handle.write(contentsOf: output.buffer)
            try output.handle.close()
            rows[kind] = output.rows
        }
        outputs = [:]
        return rows
    }

    private func open(_ kind: String) throws -> Output {
        let url = directory.appendingPathComponent(RecordingCSV.fileName(for: kind))
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let output = Output(handle: try FileHandle(forWritingTo: url))
        output.buffer.append(contentsOf: RecordingCSV.line(RecordingCSV.columns(for: kind)).utf8)
        outputs[kind] = output
        return output
    }
}
