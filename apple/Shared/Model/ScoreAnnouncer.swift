import AVFoundation
import Foundation

/// Reads the score out after each point, so it can be kept by tapping the handle with the phone in a bag.
/// Other audio is ducked while it speaks. iOS keeps speaking in the background via the `audio` background mode.
final class ScoreAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    static let enabledKey = "announceScore"
    private let synth = AVSpeechSynthesizer()

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) {
        guard isEnabled else { return }
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        #endif
        synth.stopSpeaking(at: .immediate)   // a quick correction replaces the stale call
        synth.speak(AVSpeechUtterance(string: text))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        #if os(iOS)
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
