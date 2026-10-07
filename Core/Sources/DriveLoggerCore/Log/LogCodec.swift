import Foundation

/// A whole recording, parsed.
public struct LogDocument: Hashable, Sendable {
    public var header: LogHeader
    public var events: [LogEvent]

    /// Zero-based indices of lines that failed to decode and were skipped. Only
    /// ever non-empty under `LogRecovery.skipMalformedLines`.
    public var skippedLineIndices: [Int]

    public init(header: LogHeader, events: [LogEvent], skippedLineIndices: [Int] = []) {
        self.header = header
        self.events = events
        self.skippedLineIndices = skippedLineIndices
    }
}

/// What to do about a line that doesn't decode.
public enum LogRecovery: Hashable, Sendable {
    /// Fail on the first bad line. Use when verifying a recording's integrity.
    case strict

    /// Skip bad lines and report their indices. A drive that ended with a flat
    /// battery or a crash leaves a half-written final line; losing the whole
    /// recording over that would be worse than losing one sample.
    case skipMalformedLines
}

public enum LogDecodingError: Error, Hashable, Sendable {
    /// The file was empty, or its first line wasn't a usable header.
    case missingHeader

    /// The file was written by a newer build. The reader deliberately refuses
    /// rather than guessing, because a wrong guess produces plausible-looking
    /// but wrong research data.
    case unsupportedFormatVersion(Int)

    /// A line failed to decode under `LogRecovery.strict`.
    case malformedLine(index: Int, description: String)

    /// A complete gzip member failed to decompress or failed its CRC-32 /
    /// ISIZE check, or could not be read. `index` counts members from 0 (the
    /// header member). `LogFileReader` only; under
    /// `LogRecovery.skipMalformedLines` the member is skipped and listed in
    /// `LogReadReport.damagedMemberIndices` instead.
    case damagedMember(index: Int, description: String)
}

/// Reads and writes the JSON-lines recording format.
///
/// One JSON object per line: a `LogHeader` first, then `LogEvent`s. The format is
/// append-only on purpose — a recorder can flush each line and a reader can
/// stream a multi-hundred-megabyte drive without holding it in memory.
///
/// Not `Sendable`: it owns a `JSONEncoder`/`JSONDecoder` pair. Keep one instance
/// per reader or writer, e.g. inside the actor that owns the file handle.
public final class LogCodec {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        encoder = JSONEncoder()
        // ISO 8601 rather than Foundation's reference-date Double so a header
        // stays readable with `head` and jq, in any language, in ten years.
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys make lines byte-stable across runs, which keeps fixture
        // tests meaningful; unescaped slashes keep timestamps legible.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Writing

    /// Encodes the header as a newline-terminated line.
    public func line(for header: LogHeader) throws -> Data {
        var data = try encoder.encode(header)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Encodes an event as a newline-terminated line.
    public func line(for event: LogEvent) throws -> Data {
        var data = try encoder.encode(event)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Encodes a complete recording. For export and tests; a live recorder
    /// should append `line(for:)` results as samples arrive instead.
    public func encode(_ document: LogDocument) throws -> Data {
        var data = try line(for: document.header)
        for event in document.events {
            data.append(try line(for: event))
        }
        return data
    }

    // MARK: - Reading

    /// Decodes a header line, rejecting format versions this build predates.
    public func header(from line: Data) throws -> LogHeader {
        guard let probe = try? decoder.decode(FormatVersionProbe.self, from: line) else {
            throw LogDecodingError.missingHeader
        }
        guard LogFormatVersion(rawValue: probe.formatVersion) != nil else {
            throw LogDecodingError.unsupportedFormatVersion(probe.formatVersion)
        }
        do {
            return try decoder.decode(LogHeader.self, from: line)
        } catch {
            throw LogDecodingError.missingHeader
        }
    }

    public func event(from line: Data) throws -> LogEvent {
        try decoder.decode(LogEvent.self, from: line)
    }

    /// Parses a whole recording.
    public func document(
        from data: Data,
        recovery: LogRecovery = .strict
    ) throws -> LogDocument {
        let lines = Self.split(data)
        guard let headerLine = lines.first else {
            throw LogDecodingError.missingHeader
        }

        let header = try self.header(from: headerLine)
        var events: [LogEvent] = []
        var skipped: [Int] = []
        events.reserveCapacity(lines.count - 1)

        for (offset, line) in lines.enumerated().dropFirst() {
            do {
                events.append(try event(from: line))
            } catch {
                switch recovery {
                case .strict:
                    throw LogDecodingError.malformedLine(
                        index: offset,
                        description: String(describing: error)
                    )
                case .skipMalformedLines:
                    skipped.append(offset)
                }
            }
        }

        return LogDocument(header: header, events: events, skippedLineIndices: skipped)
    }

    /// Splits on newlines, dropping blanks and tolerating CRLF.
    private static func split(_ data: Data) -> [Data] {
        data
            .split(separator: UInt8(ascii: "\n"))
            .map { line in
                var line = line
                while let last = line.last, last == UInt8(ascii: "\r") || last == UInt8(ascii: " ") {
                    line = line.dropLast()
                }
                return Data(line)
            }
            .filter { !$0.isEmpty }
    }

    /// Reads just enough of a header line to decide whether the rest is
    /// understandable. Decoding `LogHeader` directly would fail on an unknown
    /// version with an opaque enum error instead of a version number worth
    /// reporting.
    private struct FormatVersionProbe: Decodable {
        let formatVersion: Int
    }
}
