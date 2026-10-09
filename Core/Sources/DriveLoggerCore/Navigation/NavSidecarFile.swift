import Foundation

/// Where a recording's navigation sidecar lives (N4 A).
///
/// `Drive_<stamp>.jsonl.gz` has the companion `Drive_<stamp>.nav.jsonl` in
/// the same folder: the live navigation estimates the driver saw, written by
/// the app's NavigationService (N4 B). It is not part of the log format, is
/// never read by the logger or `inspect_log`, and is never listed as a
/// recording; the app exports and deletes it together with its recording.
/// `.gitignore` covers it through `*.jsonl`.
///
/// This is the one definition of the path: the writer (N4 B) and `LogStore`
/// both use `url(forRecording:)`.
public enum NavSidecarFile {
    /// Suffix that replaces the recording's `.jsonl.gz`.
    public static let suffix = ".nav.jsonl"

    /// The sidecar for `recording`: same folder, the recording's name with
    /// `.jsonl.gz` replaced by `.nav.jsonl`. A name without that extension
    /// gets the suffix appended to the whole name.
    public static func url(forRecording recording: URL) -> URL {
        let name = recording.lastPathComponent
        let recordingSuffix = "." + LogFileName.fileExtension
        let base = name.hasSuffix(recordingSuffix) ? String(name.dropLast(recordingSuffix.count)) : name
        return recording.deletingLastPathComponent().appendingPathComponent(base + suffix, isDirectory: false)
    }

    /// Whether `url` names a sidecar (by its suffix).
    public static func isSidecar(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(suffix)
    }
}
