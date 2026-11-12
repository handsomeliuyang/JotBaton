import Foundation

/// Discover roots by a stable manifest marker, independent of test subfolders.
enum RepositoryPaths {
    static func package(from file: StaticString = #filePath) -> URL {
        var directory = URL(fileURLWithPath: String(describing: file)).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
               directory.lastPathComponent == "RemarcPackage" { return directory }
            directory.deleteLastPathComponent()
        }
        preconditionFailure("Could not locate RemarcPackage from test source")
    }

    static func repository(from file: StaticString = #filePath) -> URL {
        package(from: file).deletingLastPathComponent().deletingLastPathComponent()
    }
}
