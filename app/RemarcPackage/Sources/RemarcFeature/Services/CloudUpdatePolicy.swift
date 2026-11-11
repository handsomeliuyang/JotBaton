import Foundation
import CryptoKit
import Security
import Darwin
import MachO

// Shared by the app, the publisher and the independently launched installer.
// Keep this file compatible with Swift 5.8 so the trust checks can run on Ventura.
struct CloudUpdateManifest: Codable, Equatable, Sendable {
    struct Package: Codable, Equatable, Sendable {
        let architecture: String
        let minimumOS: String
        let filename: String
        let sha256: String
        let size: Int64
    }
    let format: Int
    let version: String
    let build: Int
    let sourceCommit: String
    let publishedAt: String
    let packages: [Package]

    func validate() throws {
        guard format == 1, build > 0,
              version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
              sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              ISO8601DateFormatter().date(from: publishedAt) != nil,
              Set(packages.map(\.architecture)) == Set(["arm64", "x86_64"]), packages.count == 2,
              Set(packages.map(\.filename)).count == 2 else { throw CloudUpdateError.invalidManifest }
        for package in packages {
            guard package.filename.utf8.count <= 240, package.filename.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*\.zip$"#, options: .regularExpression) != nil,
                  package.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  package.size > 0, package.size <= 3_000_000_000,
                  package.minimumOS == (package.architecture == "arm64" ? "14.0" : "13.0") else {
                throw CloudUpdateError.invalidManifest
            }
        }
    }

    func package(for architecture: String, os: OperatingSystemVersion) throws -> Package {
        try validate()
        guard let package = packages.first(where: { $0.architecture == architecture }),
              Self.supports(package.minimumOS, os: os) else { throw CloudUpdateError.unsupportedSystem }
        return package
    }

    static func supports(_ minimum: String, os: OperatingSystemVersion) -> Bool {
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return os.majorVersion > parts[0] || (os.majorVersion == parts[0] && os.minorVersion >= parts[1])
    }
}

enum CloudUpdateError: LocalizedError {
    case invalidManifest, untrustedSignature, unsupportedSystem, invalidPackage, wrongApplication, waitingForDownload
    case operation(String)
    var errorDescription: String? {
        switch self {
        case .waitingForDownload: return "Waiting for iCloud to download the update…"
        case .invalidManifest: return "The update description is invalid."
        case .untrustedSignature: return "The update signature does not match the production identity."
        case .unsupportedSystem: return "This update does not support this Mac."
        case .invalidPackage: return "The update package failed verification."
        case .wrongApplication: return "The update does not match the installed application."
        case .operation(let message): return message
        }
    }
}

struct CloudUpdateEnvelope: Codable, Sendable {
    let format: Int
    let payload: Data
    let signature: Data
    let certificate: Data
    let algorithm: String

    func verified(fingerprint: String) throws -> CloudUpdateManifest {
        guard format == 1, payload.count <= 100_000, certificate.count <= 16_384,
              signature.count <= 16_384,
              CloudUpdateTrust.fingerprint(certificate) == fingerprint,
              let cert = SecCertificateCreateWithData(nil, certificate as CFData),
              let key = SecCertificateCopyKey(cert) else { throw CloudUpdateError.untrustedSignature }
        let algorithm = try CloudUpdateTrust.algorithm(named: algorithm)
        guard SecKeyVerifySignature(key, algorithm, payload as CFData, signature as CFData, nil) else {
            throw CloudUpdateError.untrustedSignature
        }
        let manifest = try JSONDecoder().decode(CloudUpdateManifest.self, from: payload)
        try manifest.validate()
        return manifest
    }
}

enum CloudUpdateTrust {
    static let productionFingerprint = "721E9C5FF777F0D1D9E05B44473F8F3844BBCEE5"
    static func fingerprint(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
    static func algorithm(named name: String) throws -> SecKeyAlgorithm {
        switch name {
        case "rsa-sha256": return .rsaSignatureMessagePKCS1v15SHA256
        case "ecdsa-sha256": return .ecdsaSignatureMessageX962SHA256
        default: throw CloudUpdateError.untrustedSignature
        }
    }
    static func architecture() -> String {
        // Hardware architecture, including an arm64 app launched under Rosetta.
        var arm: Int32 = 0
        var length = MemoryLayout.size(ofValue: arm)
        if sysctlbyname("hw.optional.arm64", &arm, &length, nil, 0) == 0, arm == 1 { return "arm64" }
        return "x86_64"
    }
    static func ensureDownloaded(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            throw CloudUpdateError.waitingForDownload
        }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
        if let error = values.ubiquitousItemDownloadingError { throw error }
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current {
            try fm.startDownloadingUbiquitousItem(at: url)
            throw CloudUpdateError.waitingForDownload
        }
    }
    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verifyArchive(_ file: URL, package: CloudUpdateManifest.Package) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == package.size,
              try digest(file) == package.sha256 else { throw CloudUpdateError.invalidPackage }
    }
    static func verifyCode(_ app: URL, identifier: String = "com.metepolat.Remarc") throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "identifier \"\(identifier)\" and certificate leaf = H\"\(productionFingerprint)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw CloudUpdateError.untrustedSignature
        }
    }
    static func validArchiveEntries(_ names: [String]) -> Bool {
        !names.isEmpty && names.count <= 100_000 && names.allSatisfy { name in
            let insideBundle = name.hasPrefix("Remarc.app/")
            // ditto may include AppleDouble metadata outside the app directory.
            let metadata = name.hasPrefix("__MACOSX/")
            return (insideBundle || metadata) && !name.split(separator: "/").contains("..")
        }
    }
    static func hasArchitecture(_ binary: URL, architecture: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: binary)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        func word(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let bytes = data[offset..<(offset + 4)]
            return (bigEndian ? Array(bytes) : Array(bytes.reversed())).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let wanted: UInt32
        switch architecture {
        case "arm64": wanted = UInt32(CPU_TYPE_ARM64)
        case "x86_64": wanted = UInt32(CPU_TYPE_X86_64)
        default: return false
        }
        guard let magic = word(0, bigEndian: true) else { return false }
        if magic == MH_CIGAM_64 { return word(4, bigEndian: false) == wanted }
        if magic == MH_MAGIC_64 { return word(4, bigEndian: true) == wanted }
        let bigEndian = magic == FAT_MAGIC || magic == FAT_MAGIC_64
        guard bigEndian || magic == FAT_CIGAM || magic == FAT_CIGAM_64,
              let count = word(4, bigEndian: bigEndian), count > 0, count <= 32 else { return false }
        let stride = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64 ? 32 : 20
        guard 8 + Int(count) * stride <= data.count else { return false }
        return (0..<Int(count)).contains { word(8 + $0 * stride, bigEndian: bigEndian) == wanted }
    }
    static func info(_ app: URL) throws -> [String: Any] {
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else {
            throw CloudUpdateError.wrongApplication
        }
        return info
    }
    static func verifyApplication(_ app: URL, manifest: CloudUpdateManifest, package: CloudUpdateManifest.Package) throws {
        try verifyCode(app)
        let info = try info(app)
        guard info["CFBundleIdentifier"] as? String == "com.metepolat.Remarc",
              info["CFBundleExecutable"] as? String == "Remarc",
              info["RemarcChannel"] as? String == "production",
              info["RemarcCloudUpdates"] as? Bool == true,
              info["CFBundleShortVersionString"] as? String == manifest.version,
              info["CFBundleVersion"] as? String == String(manifest.build),
              info["RemarcSourceCommit"] as? String == manifest.sourceCommit,
              [package.minimumOS, package.minimumOS + ".0"].contains(info["LSMinimumSystemVersion"] as? String ?? "") else {
            throw CloudUpdateError.wrongApplication
        }
        try verifyCode(app.appendingPathComponent("Contents/Helpers/RemarcUpdateInstaller"), identifier: "RemarcUpdateInstaller")
        // Receiving Macs do not need lipo/Xcode/Command Line Tools.
        guard try hasArchitecture(app.appendingPathComponent("Contents/MacOS/Remarc"), architecture: package.architecture) else {
            throw CloudUpdateError.unsupportedSystem
        }
        // Framework version symlinks are allowed; links escaping the bundle are not.
        let prefix = app.resolvingSymlinksInPath().path + "/"
        if let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in files where try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                guard file.resolvingSymlinksInPath().path.hasPrefix(prefix) else { throw CloudUpdateError.invalidPackage }
            }
        }
    }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CloudUpdateError.operation("Update operation failed: \(URL(fileURLWithPath: executable).lastPathComponent)") }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Filesystem transaction shared with regression tests. Call only after package
/// verification and after the parent app has stopped writing its data.
enum CloudUpdateReplacement {
    static func install(staged: URL, installed: URL, data: URL, backups: URL,
                        validateBackup: (URL) throws -> Void,
                        launch: () throws -> Void, stop: () throws -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let pending = backups.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        let retained = backups.appendingPathComponent("Previous", isDirectory: true)
        let retired = backups.appendingPathComponent(".retired-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: pending) }
        try fm.copyItem(at: installed, to: pending.appendingPathComponent("Remarc.app"))
        try validateBackup(pending.appendingPathComponent("Remarc.app"))
        let hadData = fm.fileExists(atPath: data.path)
        if hadData { try fm.copyItem(at: data, to: pending.appendingPathComponent("user-data")) }
        if fm.fileExists(atPath: retained.path) { try fm.moveItem(at: retained, to: retired) }
        do { try fm.moveItem(at: pending, to: retained) }
        catch {
            if fm.fileExists(atPath: retired.path) { try? fm.moveItem(at: retired, to: retained) }
            throw error
        }
        try? fm.removeItem(at: retired)
        let previous = installed.deletingLastPathComponent().appendingPathComponent(".remarc-previous-\(UUID().uuidString).app")
        try fm.moveItem(at: installed, to: previous)
        do { try fm.moveItem(at: staged, to: installed) }
        catch { try fm.moveItem(at: previous, to: installed); throw error }
        do { try launch() }
        catch {
            let failure = error
            // Never remove a bundle while its process is still using it.
            try stop()
            try fm.removeItem(at: installed)
            try fm.moveItem(at: previous, to: installed)
            // A failed launch may have migrated data before it stopped.
            let restore = data.deletingLastPathComponent().appendingPathComponent(".remarc-restore-\(UUID().uuidString)")
            if hadData { try fm.copyItem(at: retained.appendingPathComponent("user-data"), to: restore) }
            if fm.fileExists(atPath: data.path) {
                try fm.moveItem(at: data, to: retained.appendingPathComponent("failed-user-data"))
            }
            if hadData { try fm.moveItem(at: restore, to: data) }
            throw failure
        }
        try? fm.removeItem(at: previous)
    }
}
