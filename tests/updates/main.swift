import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
var checks = 0
func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { fatalError(message) }
    checks += 1
}
func rejected(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError(message) } catch { checks += 1 }
}
func write(_ string: String, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(string.utf8).write(to: url)
}
func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
let bytes = try Data(contentsOf: root.appendingPathComponent("latest.json"))
let envelope = try JSONDecoder().decode(CloudUpdateEnvelope.self, from: bytes)
let fingerprint = CloudUpdateTrust.fingerprint(envelope.certificate)
let manifest = try envelope.verified(fingerprint: fingerprint)
try expect(manifest.build == 42, "signed payload")
try expect(try manifest.package(for: "x86_64", os: .init(majorVersion: 13, minorVersion: 7, patchVersion: 8)).architecture == "x86_64", "Ventura package")
try expect(try manifest.package(for: "arm64", os: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0)).architecture == "arm64", "ARM package")
rejected("wrong signer") { _ = try envelope.verified(fingerprint: CloudUpdateTrust.productionFingerprint) }
rejected("unsupported OS") { _ = try manifest.package(for: "arm64", os: .init(majorVersion: 13, minorVersion: 7, patchVersion: 8)) }
rejected("unsupported arch") { _ = try manifest.package(for: "i386", os: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0)) }
let tampered = CloudUpdateEnvelope(format: envelope.format, payload: envelope.payload + Data(" ".utf8), signature: envelope.signature, certificate: envelope.certificate, algorithm: envelope.algorithm)
rejected("tampered payload") { _ = try tampered.verified(fingerprint: fingerprint) }
let badAlgorithm = CloudUpdateEnvelope(format: envelope.format, payload: envelope.payload, signature: envelope.signature, certificate: envelope.certificate, algorithm: "none")
rejected("unknown algorithm") { _ = try badAlgorithm.verified(fingerprint: fingerprint) }
var object = try JSONSerialization.jsonObject(with: envelope.payload) as! [String: Any]
let valid = object
for (key, value) in [("format", 2 as Any), ("build", 0 as Any), ("version", "1.02.3" as Any), ("sourceCommit", "oops" as Any), ("publishedAt", "yesterday" as Any)] {
    object = valid; object[key] = value
    rejected("invalid \(key)") { try JSONDecoder().decode(CloudUpdateManifest.self, from: JSONSerialization.data(withJSONObject: object)).validate() }
}
for filename in ["../escape.zip", "/tmp/escape.zip", "x/y.zip", "shell$(id).zip", "archive.dmg"] {
    object = valid
    var packages = object["packages"] as! [[String: Any]]
    packages[0]["filename"] = filename; object["packages"] = packages
    rejected("unsafe archive name") { try JSONDecoder().decode(CloudUpdateManifest.self, from: JSONSerialization.data(withJSONObject: object)).validate() }
}
object = valid
var packages = object["packages"] as! [[String: Any]]
packages[1] = packages[0]; object["packages"] = packages
rejected("duplicate architecture") { try JSONDecoder().decode(CloudUpdateManifest.self, from: JSONSerialization.data(withJSONObject: object)).validate() }
let archive = root.appendingPathComponent("payload.zip")
try CloudUpdateTrust.verifyArchive(archive, package: manifest.packages[0])
checks += 1
try Data("changed".utf8).write(to: archive)
rejected("changed archive") { try CloudUpdateTrust.verifyArchive(archive, package: manifest.packages[0]) }

try CloudUpdateTrust.ensureDownloaded(root.appendingPathComponent("latest.json"))
checks += 1
rejected("missing cloud archive remains pending") { try CloudUpdateTrust.ensureDownloaded(root.appendingPathComponent("not-arrived.zip")) }
let installedProduction = URL(fileURLWithPath: "/Applications/Remarc.app")
if fm.fileExists(atPath: installedProduction.path) {
    try CloudUpdateTrust.verifyCode(installedProduction)
    checks += 1
}

let mach = root.appendingPathComponent("mach-o")
// Little-endian 64-bit ARM executable header.
try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]).write(to: mach)
try expect(try CloudUpdateTrust.hasArchitecture(mach, architecture: "arm64"), "native ARM Mach-O")
try expect(try !CloudUpdateTrust.hasArchitecture(mach, architecture: "x86_64"), "reject wrong native architecture")
// Fat header with one Intel slice and its offset/size/alignment fields.
try (Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1, 1, 0, 0, 7]) + Data(repeating: 0, count: 16)).write(to: mach)
try expect(try CloudUpdateTrust.hasArchitecture(mach, architecture: "x86_64"), "fat Intel Mach-O")
try expect(try !CloudUpdateTrust.hasArchitecture(mach, architecture: "arm64"), "reject absent fat architecture")
try Data([0xca, 0xfe, 0xba, 0xbe, 0xff, 0xff, 0xff, 0xff]).write(to: mach)
try expect(try !CloudUpdateTrust.hasArchitecture(mach, architecture: "arm64"), "reject malformed fat header")
// This executable has a known architecture regardless of the installed app.
// The installed production app may be native ARM or Intel (including Rosetta).
#if arch(arm64)
let nativeArchitecture = "arm64"
let otherArchitecture = "x86_64"
#else
let nativeArchitecture = "x86_64"
let otherArchitecture = "arm64"
#endif
let testBinary = URL(fileURLWithPath: CommandLine.arguments[0])
try expect(try CloudUpdateTrust.hasArchitecture(testBinary, architecture: nativeArchitecture), "real native binary without developer tools")
try expect(try !CloudUpdateTrust.hasArchitecture(testBinary, architecture: otherArchitecture), "real native binary rejects other architecture")

try expect(CloudUpdateTrust.validArchiveEntries(["Remarc.app/", "Remarc.app/Contents/Info.plist", "__MACOSX/._Remarc.app"]), "ditto metadata accepted")
try expect(!CloudUpdateTrust.validArchiveEntries(["Remarc.app/../../escape"]), "ZIP traversal rejected")
try expect(!CloudUpdateTrust.validArchiveEntries(["/Remarc.app/Contents/file"]), "absolute ZIP path rejected")
try expect(!CloudUpdateTrust.validArchiveEntries(["other.app/Contents/file"]), "unrelated ZIP root rejected")

// Exercise actual filesystem replacement and restoration with simulated launch failures.
for mode in ["success", "failed-launch", "failed-backup", "refused-stop", "first-run-failure"] {
    let base = root.appendingPathComponent(mode, isDirectory: true)
    let installed = base.appendingPathComponent("Applications/Remarc.app")
    let staged = base.appendingPathComponent("Applications/new.app")
    let data = base.appendingPathComponent("Support/Remarc")
    let backups = base.appendingPathComponent("Backups")
    try write("old", installed.appendingPathComponent("code"))
    try write("new", staged.appendingPathComponent("code"))
    if mode != "first-run-failure" { try write("original", data.appendingPathComponent("comments.json")) }
    try write("older", backups.appendingPathComponent("Previous/Remarc.app/code"))
    var threw = false
    do {
        try CloudUpdateReplacement.install(staged: staged, installed: installed, data: data, backups: backups,
            validateBackup: { _ in if mode == "failed-backup" { throw CloudUpdateError.invalidPackage } }, launch: {
                if mode != "success" {
                    try write("migrated", data.appendingPathComponent("comments.json"))
                    throw CloudUpdateError.operation("Simulated launch failure")
                }
            }, stop: { if mode == "refused-stop" { throw CloudUpdateError.operation("Process would not stop") } })
    } catch { threw = true }
    try expect(threw == (mode != "success"), "transaction outcome \(mode)")
    if mode == "success" {
        try expect(try read(installed.appendingPathComponent("code")) == "new", "new app")
        try expect(try read(backups.appendingPathComponent("Previous/Remarc.app/code")) == "old", "one previous app")
        try expect(try read(data.appendingPathComponent("comments.json")) == "original", "data kept")
        try expect(try fm.contentsOfDirectory(atPath: backups.path) == ["Previous"], "one stable backup")
    } else if mode == "refused-stop" {
        try expect(try read(installed.appendingPathComponent("code")) == "new", "never remove running app")
        try expect(try read(backups.appendingPathComponent("Previous/Remarc.app/code")) == "old", "backup recoverable")
    } else {
        try expect(try read(installed.appendingPathComponent("code")) == "old", "restore old app")
        if mode == "first-run-failure" {
            try expect(!fm.fileExists(atPath: data.path), "restore absence of original data")
        } else {
            try expect(try read(data.appendingPathComponent("comments.json")) == "original", "restore old data")
        }
        if mode == "failed-backup" {
            try expect(try read(backups.appendingPathComponent("Previous/Remarc.app/code")) == "older", "preserve existing backup")
        } else {
            try expect(try read(backups.appendingPathComponent("Previous/failed-user-data/comments.json")) == "migrated", "retain failed data")
        }
    }
}
print("Cloud update trust and filesystem transaction checks passed: \(checks)")
