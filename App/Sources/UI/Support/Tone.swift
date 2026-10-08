import SwiftUI

/// How loudly a piece of state should look. Views map it to a colour in one
/// place, so "red means not recording or adapter lost" is a single rule.
enum Tone: Hashable, Sendable {
    /// Working as intended (recording, polling).
    case good
    /// In progress or needs attention, not yet wrong.
    case caution
    /// Not recording, adapter lost, failed.
    case bad
    /// Informational, no judgement.
    case neutral

    var color: Color {
        switch self {
        case .good: .green
        case .caution: .orange
        case .bad: .red
        case .neutral: .gray
        }
    }
}
