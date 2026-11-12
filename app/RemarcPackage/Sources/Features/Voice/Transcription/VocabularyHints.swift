import Foundation
@preconcurrency import WhisperKit

package enum VocabularyHints {
    package static let defaultHints: [String] = ["Remarc", "Claude Code"]

    @MainActor
    package static var words: [String] {
        UserDefaults.standard.stringArray(forKey: VoiceModelPreferences.vocabularyHintsKey) ?? defaultHints
    }

    @MainActor
    package static func whisperPromptTokens(using tokenizer: WhisperTokenizer) -> [Int] {
        tokenizer.encode(text: words.joined(separator: ", "))
    }
}
