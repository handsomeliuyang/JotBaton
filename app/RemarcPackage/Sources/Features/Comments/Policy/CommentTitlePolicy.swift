import Foundation

/// Normalizes legacy titles without generating or displaying new titles.
package enum CommentTitlePolicy {
    package static func normalizedCustomTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
