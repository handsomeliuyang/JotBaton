import Foundation

/// Normalizes legacy titles without generating or displaying new titles.
enum CommentTitlePolicy {
    static func normalizedCustomTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
