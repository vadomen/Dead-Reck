import Darwin
import Foundation

/// The app's memory footprint (`phys_footprint`, what Xcode's memory gauge
/// and jetsam count), for the device check D1 (road network memory).
enum MemoryFootprint {
    static func currentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// "123.4 MB" (decimal megabytes), or "--".
    static func format(_ bytes: UInt64?) -> String {
        guard let bytes else { return "--" }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
