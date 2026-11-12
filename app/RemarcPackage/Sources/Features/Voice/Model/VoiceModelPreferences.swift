import Foundation

/// Read the same channel's preference without depending on the settings screen.
public enum VoiceModelPreferences {
    public static let vocabularyHintsKey = "vocabularyHints"
    public static let pauseMusicKey = "pauseMusicWhileRecording"
    public static let keepInMemoryKey = "keepModelInMemory"
    public static func keepInMemory(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: keepInMemoryKey)
    }
}
