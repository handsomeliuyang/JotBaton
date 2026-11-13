// Verify with the app's pinned public key, independently of the release signing secret.
import CryptoKit
import Foundation

let args = CommandLine.arguments
func reject() -> Never {
    FileHandle.standardError.write(Data("Update signature verification failed\n".utf8))
    exit(1)
}
guard args.count == 4, let key = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[3]) else { reject() }
do {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
    guard publicKey.isValidSignature(signature, for: data) else { reject() }
} catch { reject() }
