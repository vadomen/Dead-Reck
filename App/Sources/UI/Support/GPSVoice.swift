import AVFoundation
import Foundation

// UX-22 voice: three optional phrases on a change of the HUD's GPS state.
// The decisions (what triggers a phrase, the rate limit) are plain values and
// unit-tested (`GPSVoiceTests`); the speech output is the only AVFoundation
// part and sits behind `GPSSpeaking`.

/// The Settings switch's `@AppStorage` key. An on-disk string: never rename it.
enum GPSVoiceSetting {
    static let key = "voice.gpsChanges"
}

enum GPSPhrase: String, CaseIterable, Hashable, Sendable {
    /// "GPS" to "No GPS": the fixes stopped or became unusable, after having been in use.
    case lost = "GPS lost"
    /// "No GPS" to "GPS", after a "GPS lost" was seen in this run. The first
    /// fix of a run is not "back".
    case back = "GPS back"
    /// The driver's switch went off (their own tap, said back to them).
    case off = "GPS off"
}

/// Which phrase, if any, a new HUD GPS state calls for. One per run; it is
/// reset whenever no run is live, so Stop and the next Start's first fix
/// never speak.
struct GPSPhraseTracker: Equatable, Sendable {
    private var previous: HUDGPS?
    private var lostSeen = false

    /// Feed every state (also while the voice is off, so switching it on
    /// later does not speak a stale change). Returns the phrase for this change.
    ///
    /// - Switch off (from GPS or No GPS): "GPS off".
    /// - Switch on again: nothing (the driver just tapped it). The state it lands in is the new baseline.
    /// - GPS to No GPS: "GPS lost". No GPS to GPS: "GPS back", only after a "lost".
    mutating func note(_ state: HUDGPS, runActive: Bool) -> GPSPhrase? {
        guard runActive else {
            previous = nil
            lostSeen = false
            return nil
        }
        defer { previous = state }
        guard let old = previous, old != state else { return nil }
        switch (old, state) {
        case (_, .off): return .off
        case (.off, _): return nil
        case (.ok, .none):
            lostSeen = true
            return .lost
        case (.none, .ok):
            defer { lostSeen = false }
            return lostSeen ? .back : nil
        default: return nil
        }
    }
}

/// At most once per `minInterval` per phrase; phrases are independent.
struct GPSPhraseLimiter: Equatable, Sendable {
    static let minInterval: TimeInterval = 300

    private var lastSpoken: [GPSPhrase: TimeInterval] = [:]

    /// True and recorded when `phrase` may be spoken at `now` (seconds, any
    /// monotonic base); false when it was spoken less than 5 minutes ago.
    mutating func allow(_ phrase: GPSPhrase, now: TimeInterval) -> Bool {
        if let last = lastSpoken[phrase], now - last < Self.minInterval { return false }
        lastSpoken[phrase] = now
        return true
    }
}

protocol GPSSpeaking: AnyObject {
    @MainActor func speak(_ text: String)
}

/// Tracker + limiter + the Settings switch. Off by default; with it off
/// nothing is ever spoken (the demo included).
@MainActor
final class GPSVoiceAnnouncer {
    private var tracker = GPSPhraseTracker()
    private var limiter = GPSPhraseLimiter()
    private let speaker: any GPSSpeaking
    private let now: () -> TimeInterval

    init(speaker: any GPSSpeaking = SystemSpeech(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.speaker = speaker
        self.now = now
    }

    /// The HUD's GPS state (and whether a run is live) as of now.
    @discardableResult
    func note(_ state: HUDGPS, runActive: Bool, enabled: Bool) -> GPSPhrase? {
        guard let phrase = tracker.note(state, runActive: runActive), enabled,
              limiter.allow(phrase, now: now()) else { return nil }
        speaker.speak(phrase.rawValue)
        return phrase
    }
}

/// Speaks through the system synthesizer as a navigation prompt: `.playback`
/// with `.voicePrompt`, other audio ducked while it talks, session released
/// (others restored) when the last phrase ends.
@MainActor
final class SystemSpeech: NSObject, GPSSpeaking, @preconcurrency AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            return
        }
        pending += 1
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished() }

    private func finished() {
        pending = max(0, pending - 1)
        guard pending == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
