import Foundation

enum CommentTitlePolicy {
    static let untitled = "未命名任务"

    static func normalizedCustomTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    static func automaticTitle(reference: String?, body: String, filePath: String? = nil) -> String {
        for candidate in [reference, body] {
            guard let candidate,
                  let firstLine = candidate.split(whereSeparator: \.isNewline)
                    .compactMap({ normalizedCustomTitle(String($0)) }).first else { continue }
            return String(firstLine.prefix(24))
        }
        if let filePath, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            let generatedScreenshot = name.range(
                of: #"^(screenshot|screen shot|截屏|屏幕截图)[ _-]*[0-9]"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            if UUID(uuidString: name) == nil, !generatedScreenshot,
               name.contains(where: { $0.isLetter }), let normalized = normalizedCustomTitle(name) {
                return String(normalized.prefix(24))
            }
        }
        return untitled
    }
}
