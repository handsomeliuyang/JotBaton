import CoreLocalization
import Foundation

package enum CloudSyncError: LocalizedError {
    case message(String)
    case underlying(String, NSError)

    package var errorDescription: String? {
        switch self {
        case .message(let message), .underlying(let message, _): return message
        }
    }
}

/// A sync failure reduced to what the user can act on. Persisted, so it stores
/// only error domains and codes, never paths, account identifiers or file data.
package struct CloudSyncIssue: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case permission, cloudUnavailable, quota, unavailable, other }
    package enum Stage: String, Codable, Sendable { case connection, preparing, applying, publishing, localRecord }
    package let kind: Kind
    package let stage: Stage
    package let message: String
    package let codes: [String]
    package let date: Date

    package var needsAuthorization: Bool { kind == .permission }
    package var needsICloudSettings: Bool { kind == .cloudUnavailable || kind == .quota || kind == .unavailable }
    package var diagnostic: String {
        "Stage: \(stage.rawValue)\nTime: \(date.formatted(date: .numeric, time: .standard))\nErrors: \(codes.joined(separator: " → "))"
    }

    package static func make(_ error: Error, stage: Stage) -> Self {
        var errors: [NSError] = []
        var next = error as NSError
        if let wrapped = error as? CloudSyncError, case .underlying(_, let underlying) = wrapped { next = underlying }
        for _ in 0..<5 {
            errors.append(next)
            guard let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            next = underlying
        }
        func contains(_ domain: String, _ codes: [Int]) -> Bool {
            errors.contains { $0.domain == domain && codes.contains($0.code) }
        }
        let kind: Kind
        let message: String
        if stage == .localRecord {
            kind = .other
            message = "Sync progress could not be saved on this Mac. Your tasks are kept."
        } else if contains(NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError]) || contains(NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)]) {
            kind = .permission
            message = "JotBaton cannot access the iCloud sync files."
        } else if contains(NSCocoaErrorDomain, [NSUbiquitousFileNotUploadedDueToQuotaError]) || contains("NSFileProviderErrorDomain", [-1003]) {
            kind = .quota
            message = "iCloud storage is full. Upload is not confirmed."
        } else if contains(NSCocoaErrorDomain, [NSUbiquitousFileUbiquityServerNotAvailable]) || contains("NSFileProviderErrorDomain", [-1000, -1004]) || errors.contains(where: { $0.domain == NSURLErrorDomain }) {
            kind = .cloudUnavailable
            message = "iCloud could not confirm the upload or connection."
        } else if stage == .connection {
            kind = .unavailable
            message = error.localizedDescription
        } else {
            kind = .other
            message = error.localizedDescription
        }
        return Self(kind: kind, stage: stage, message: message,
                    codes: errors.map { "\($0.domain) (\($0.code))" }, date: Date())
    }
}
