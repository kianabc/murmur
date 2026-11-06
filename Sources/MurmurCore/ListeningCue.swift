import AppKit

/// A soft tick at the moment Murmur can hear you.
///
/// On a built-in microphone that's the moment you press. On AirPods it's about
/// two-thirds of a second later, after they've switched into call mode — words
/// spoken before then are never recorded, and the tick lets you know when to
/// start without watching the popup.
public enum ListeningCue {
    private static let key = "com.torimi.murmur.listeningTick"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Quiet enough not to startle, and short enough that the recogniser
    /// doesn't hear it as a word.
    static let volume: Float = 0.3

    private static let sound: NSSound? = {
        let s = NSSound(named: "Tink")?.copy() as? NSSound
        s?.volume = volume
        return s
    }()

    public static func play() {
        guard isEnabled, let sound else { return }
        sound.stop()
        sound.play()
    }
}
