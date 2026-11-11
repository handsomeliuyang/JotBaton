import Foundation
import Security

func identity(in path: String) throws -> SecIdentity {
    var keychain: SecKeychain?
    guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { throw CloudUpdateError.operation("Open and unlock the dedicated production keychain first.") }
    let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
        kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        kSecMatchSearchList as String: [keychain]]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let identities = result as? [SecIdentity] else { throw CloudUpdateError.untrustedSignature }
    for identity in identities {
        var certificate: SecCertificate?
        if SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
           CloudUpdateTrust.fingerprint(SecCertificateCopyData(certificate) as Data) == CloudUpdateTrust.productionFingerprint {
            return identity
        }
    }
    throw CloudUpdateError.untrustedSignature
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw CloudUpdateError.operation("Expected preflight, sign, verify, verify-app or upload-state.") }
    switch command {
    case "preflight":
        guard args.count == 2 else { throw CloudUpdateError.invalidManifest }
        _ = try identity(in: args[1])
        print("Production identity is available and matches the pinned fingerprint.")
    case "sign":
        guard args.count == 4 else { throw CloudUpdateError.invalidManifest }
        let payload = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let manifest = try JSONDecoder().decode(CloudUpdateManifest.self, from: payload)
        try manifest.validate()
        let identity = try identity(in: args[3])
        var certificate: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else { throw CloudUpdateError.untrustedSignature }
        let name = SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256) ? "rsa-sha256" : "ecdsa-sha256"
        guard let signature = SecKeyCreateSignature(key, try CloudUpdateTrust.algorithm(named: name), payload as CFData, nil) else { throw CloudUpdateError.untrustedSignature }
        let envelope = CloudUpdateEnvelope(format: 1, payload: payload, signature: signature as Data,
            certificate: SecCertificateCopyData(certificate) as Data, algorithm: name)
        _ = try envelope.verified(fingerprint: CloudUpdateTrust.productionFingerprint)
        try JSONEncoder().encode(envelope).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        print("Signed and verified the update description.")
    case "verify", "verify-app":
        guard args.count == (command == "verify" ? 2 : 4) else { throw CloudUpdateError.invalidManifest }
        let envelope = try JSONDecoder().decode(CloudUpdateEnvelope.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let manifest = try envelope.verified(fingerprint: CloudUpdateTrust.productionFingerprint)
        if command == "verify-app" {
            guard let package = manifest.packages.first(where: { $0.architecture == args[3] }) else { throw CloudUpdateError.unsupportedSystem }
            try CloudUpdateTrust.verifyApplication(URL(fileURLWithPath: args[2]), manifest: manifest, package: package)
        }
        print("Verified update \(manifest.version) (\(manifest.build)).")
    case "cloud-read":
        guard args.count == 3 else { throw CloudUpdateError.invalidManifest }
        let source = URL(fileURLWithPath: args[1])
        try CloudUpdateTrust.ensureDownloaded(source)
        var failure: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &failure) { url in
            result = Result {
                let data = try Data(contentsOf: url)
                guard data.count <= 256_000 else { throw CloudUpdateError.invalidManifest }
                try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
            }
        }
        if let failure { throw failure }
        guard let result else { throw CloudUpdateError.invalidManifest }
        try result.get()
    case "commit":
        guard args.count == 4 else { throw CloudUpdateError.invalidManifest }
        let source = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let envelope = try JSONDecoder().decode(CloudUpdateEnvelope.self, from: source)
        _ = try envelope.verified(fingerprint: CloudUpdateTrust.productionFingerprint)
        let target = URL(fileURLWithPath: args[2])
        var failure: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &failure) { url in
            result = Result {
                let exists = FileManager.default.fileExists(atPath: url.path)
                let actual = exists ? try CloudUpdateTrust.digest(url) : "-"
                guard actual == args[3] else {
                    throw CloudUpdateError.operation("Cloud update changed while building. No description was overwritten.")
                }
                try source.write(to: url, options: .atomic)
            }
        }
        if let failure { throw failure }
        guard let result else { throw CloudUpdateError.invalidManifest }
        try result.get()
    case "cleanup":
        guard args.count >= 3 else { throw CloudUpdateError.invalidManifest }
        let expected = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let envelope = try JSONDecoder().decode(CloudUpdateEnvelope.self, from: expected)
        let manifest = try envelope.verified(fingerprint: CloudUpdateTrust.productionFingerprint)
        let keep = Set(manifest.packages.map(\.filename))
        let knownPrevious = Set(args.dropFirst(3))
        let latest = URL(fileURLWithPath: args[2])
        let directory = latest.deletingLastPathComponent()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey]
        for listed in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            let originalName = listed.lastPathComponent
            let placeholder = originalName.hasPrefix(".") && originalName.hasSuffix(".icloud")
            let name = placeholder ? String(originalName.dropFirst().dropLast(7)) : originalName
            let file = directory.appendingPathComponent(name)
            guard !keep.contains(name), name.range(of: #"^(?:\.upload-)?Remarc-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}(?:[+-][0-9]{4})?-(?:arm64|x86_64)\.zip$"#, options: .regularExpression) != nil else { continue }
            let values = try listed.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.ubiquitousItemIsUploading != true,
                  values.ubiquitousItemIsUploaded == true || (placeholder && knownPrevious.contains(name)),
                  knownPrevious.contains(name) || (values.contentModificationDate.map { Date().timeIntervalSince($0) > 86400 } == true) else { continue }
            var failure: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(readingItemAt: latest, options: [], writingItemAt: file, options: .forDeleting, error: &failure) { description, target in
                result = Result {
                    guard try Data(contentsOf: description) == expected else { throw CloudUpdateError.operation("Cloud update changed during cleanup; no further files were removed.") }
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    else if placeholder { try FileManager.default.removeItem(at: listed) }
                }
            }
            if let failure { throw failure }
            if let result { try result.get() }
        }
    case "upload-state":
        guard args.count == 2 else { throw CloudUpdateError.invalidManifest }
        let values = try URL(fileURLWithPath: args[1]).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
        if values.isUbiquitousItem == true && values.ubiquitousItemIsUploaded == true { print("uploaded") }
        else if let error = values.ubiquitousItemUploadingError { throw error }
        else { print(values.isUbiquitousItem == true ? "uploading" : "not-cloud") }
    default: throw CloudUpdateError.invalidManifest
    }
} catch {
    // No identity/password material or process arguments are included in errors.
    fputs("Cloud update operation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
