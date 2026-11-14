@testable import CorePlatform
@testable import FeatureCloudSync
@testable import RemarcFeature
import Foundation
import Testing

struct AppIdentityTests {
    @Test func productionKeepsLocalIdentityAndUsesBrandedCloudFolder() {
        let identity = AppIdentity.production
        #expect(identity.displayName == "JotBaton")
        #expect(identity.bundleIdentifier == "com.metepolat.Remarc")
        #expect(identity.appSupportURL(in: URL(fileURLWithPath: "/Users/test")).path == "/Users/test/Library/Application Support/Remarc")
        #expect(identity.cloudDirectoryName == "JotBaton")
        #expect(identity.cloudDisplayPath == "iCloud Drive/JotBaton")
        #expect(identity.cloudURL(in: URL(fileURLWithPath: "/cloud")).path == "/cloud/JotBaton")
        #expect(identity.urlScheme == "remarc")
        #expect(identity.webSocketPort == 9274)
    }

    @Test func channelsDoNotShareFilesCallbacksOrPorts() {
        let home = URL(fileURLWithPath: "/Users/test")
        let drive = URL(fileURLWithPath: "/cloud")
        let dev = AppIdentity.development
        let release = AppIdentity.production
        #expect(dev.displayName == "JotBaton Dev")
        #expect(dev.directoryName == "Remarc Dev")
        #expect(dev.appSupportURL(in: home) != release.appSupportURL(in: home))
        #expect(dev.cloudURL(in: drive) != release.cloudURL(in: drive))
        #expect(dev.cloudDirectoryName == "JotBaton Dev")
        #expect(dev.cloudDisplayPath == "iCloud Drive/JotBaton Dev")
        #expect(dev.cloudURL(in: drive).path == "/cloud/JotBaton Dev")
        #expect(dev.bundleIdentifier != release.bundleIdentifier)
        #expect(dev.urlScheme != release.urlScheme)
        #expect(dev.webSocketPort != release.webSocketPort)
        #expect(dev.menuBarIconName != release.menuBarIconName)
        #expect(dev.appIconName != release.appIconName)
    }

    @Test func cloudChannelsCannotAuthorizeEachOthersFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inspect: (URL) throws -> CloudSyncLocation.Facts = { url in
            let facts = try CloudSyncLocation.inspect(url)
            return .init(isDirectory: facts.isDirectory, isCloudItem: url == root, isSymbolicLink: facts.isSymbolicLink)
        }
        for channel in AppIdentity.allCases {
            let legacy = root.appendingPathComponent(channel.directoryName)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
            let oldBackup = legacy.appendingPathComponent("current.json")
            let bytes = Data("old cloud backup".utf8)
            try bytes.write(to: oldBackup)
            let folder = try CloudSyncLocation.connect(root: root, createIfMissing: true, channel: channel, inspect: inspect)
            #expect(folder == channel.cloudURL(in: root))
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
            #expect(try Data(contentsOf: oldBackup) == bytes)
            #expect(CloudSyncLocation.isAuthorizationLocation(folder, root: root, channel: channel))
            let other: AppIdentity = channel == .production ? .development : .production
            #expect(!CloudSyncLocation.isAuthorizationLocation(folder, root: root, channel: other))
            #expect(!CloudSyncLocation.isAuthorizationLocation(root.appendingPathComponent(channel.directoryName), root: root, channel: channel))
        }
    }
}
