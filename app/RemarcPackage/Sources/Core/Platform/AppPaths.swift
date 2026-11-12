import Foundation

/// The real storage root. Computed once; the app never uses anything else.
private let productionAppSupportURL: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent(AppIdentity.current.directoryName, isDirectory: true)
}()

/// Set only by tests, to redirect every path helper at a temporary directory.
///
/// Without this the suite reads and writes the user's live
/// `~/Library/Application Support/Remarc`: it created images there, left
/// deliberately corrupt sidecars behind when a case failed before its teardown,
/// and two concurrent runs fought over the same files. A running Remarc then
/// found those fixtures and logged them as real corruption.
package nonisolated(unsafe) var remarcAppSupportOverride: URL?

package var remarcAppSupportURL: URL {
    remarcAppSupportOverride ?? productionAppSupportURL
}
