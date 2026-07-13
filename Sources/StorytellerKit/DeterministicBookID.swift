import CryptoKit
import Foundation

package enum DeterministicBookID {
  // A project-owned UUID namespace. The name is a stable source fingerprint,
  // so retries and separate product uploads address the same remote book.
  package static let namespace = UUID(uuidString: "660ae3b7-b7a4-5e32-8dbd-bfbcc29e017c")!

  package static func make(sourceSHA256: String) -> UUID {
    make(name: sourceSHA256.lowercased())
  }

  package static func make(catalogID: UUID) -> UUID {
    make(name: "catalog:\(catalogID.uuidString.lowercased())")
  }

  private static func make(name: String) -> UUID {
    var namespaceBytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
    namespaceBytes.append(contentsOf: name.utf8)
    var bytes = Array(Insecure.SHA1.hash(data: Data(namespaceBytes)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
