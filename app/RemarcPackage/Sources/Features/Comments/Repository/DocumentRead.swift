import CorePlatform
import Foundation

/// What was found on disk before a merge, with "not there yet" kept distinct
/// from "there but unreadable".
///
/// Both save paths used to collapse these: any failure to decode fell back to
/// the in-memory snapshot, which was then merged and written over the file. So
/// a document this build could not parse - such as a newer app version -
/// was replaced by whatever this build happened to
/// be holding. That is the whole file, including every comment the user had.
///
/// A missing file is genuinely empty and safe to write. An unreadable one is
/// not ours to overwrite.
package enum DocumentRead {
    case absent
    case decoded(AppState)
    case unreadable(reason: String)

    package static func read(_ fileURL: URL) -> DocumentRead {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .unreadable(reason: "file exists but could not be read")
        }
        // A zero-byte file is a truncated write, not a fresh start. Treating it
        // as absent is what would let a crash mid-write turn into a wipe.
        guard !data.isEmpty else { return .unreadable(reason: "file is empty") }
        do {
            return .decoded(try JSONDecoder().decode(AppState.self, from: data))
        } catch {
            return .unreadable(reason: "\(error)")
        }
    }
}

/// Thrown instead of overwriting a document this build cannot parse.
package struct DocumentUnreadable: Error {
    package init(reason: String) { self.reason = reason }
    package let reason: String
}

package enum DocumentRecovery {
    /// Write the in-memory document beside the file we refused to overwrite.
    ///
    /// Refusing to write protects the file but strands the user's unsaved work,
    /// so it goes somewhere recoverable rather than nowhere. Best-effort by
    /// design: failing to write a recovery copy must not turn into a second
    /// error on top of the first.
    package static func dump(_ state: AppState, beside fileURL: URL, reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = fileURL.deletingLastPathComponent()
            .appendingPathComponent("comments.recovered-\(stamp).json")
        guard !FileManager.default.fileExists(atPath: url.path),
              let data = try? JSONEncoder().encode(state)
        else { return }
        try? data.write(to: url, options: .atomic)
        debugLog(
            "DocumentRecovery: refused to overwrite an unreadable \(fileURL.lastPathComponent) "
            + "(\(reason)); in-memory state saved to \(url.lastPathComponent)"
        )
    }
}
