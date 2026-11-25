import CorePlatform
import Foundation

/// Apple iCloud Drive storage backend (`iCloud Drive/JotBaton[ Dev]`).
package struct ICloudStorageProvider: StorageProvider {
    package let kind: StorageProviderKind = .iCloud
    package let supportsSystemCloudSettings = true

    private let connector: @Sendable (Bool, Bool) throws -> URL

    package init(root: URL = CloudSyncLocation.driveRoot,
                 channel: AppIdentity = .current,
                 inspect: @escaping @Sendable (URL) throws -> CloudSyncLocation.Facts = { try CloudSyncLocation.inspect($0) }) {
        self.connector = { createIfMissing, verifyWriteAccess in
            try CloudSyncLocation.connect(root: root, createIfMissing: createIfMissing,
                                          verifyWriteAccess: verifyWriteAccess, channel: channel, inspect: inspect)
        }
    }

    package init(connect: @escaping @Sendable (Bool) throws -> URL) {
        self.connector = { createIfMissing, _ in try connect(createIfMissing) }
    }

    package func connect(createIfMissing: Bool, verifyWriteAccess: Bool) throws -> URL {
        try connector(createIfMissing, verifyWriteAccess)
    }

    package func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: CloudFileStatus.iCloudPlaceholder(for: url).path)
    }

    package func availability(_ url: URL) -> SyncFileAvailability {
        CloudFileStatus.availability(url, checksICloudPlaceholder: true)
    }

    package func listDevices(_ layout: SyncLayout) throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(atPath: layout.devices.path).compactMap { name in
            var name = name
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }

    package func listBlobs(_ layout: SyncLayout) throws -> [SyncBlobEntry] {
        try CloudFileStatus.listBlobs(in: layout.blobs, includeICloudPlaceholders: true)
    }

    package func readData(at url: URL) throws -> Data {
        try SyncIO.coordinate(url, writing: false) { try Data(contentsOf: $0, options: .mappedIfSafe) }
    }

    package func writeData(_ data: Data, to url: URL, onlyIfMissing: Bool) throws {
        try SyncIO.coordinate(url, writing: true) { target in
            if onlyIfMissing, FileManager.default.fileExists(atPath: target.path) { return }
            try data.write(to: target, options: .atomic)
        }
    }

    package func deleteItem(at url: URL) throws {
        let fm = FileManager.default
        let placeholder = CloudFileStatus.iCloudPlaceholder(for: url)
        if fm.fileExists(atPath: url.path) {
            try CloudFileStatus.deleteCoordinated(url)
        }
        if fm.fileExists(atPath: placeholder.path) {
            try CloudFileStatus.deleteCoordinated(placeholder)
        }
    }

    package func uploadState(_ url: URL) throws -> Bool? {
        try CloudFileStatus.uploadState(url)
    }
}
