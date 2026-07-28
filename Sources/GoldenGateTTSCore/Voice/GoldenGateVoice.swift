import Foundation

package struct GoldenGateVoice: Codable, Hashable, Sendable {
  package let id: String
  package let name: String
  package let language: String
  package let quality: String
  package let gender: Int
  package let revision: String

  package init(
    id: String, name: String, language: String, quality: String,
    gender: Int, revision: String
  ) {
    self.id = id
    self.name = name
    self.language = language
    self.quality = quality
    self.gender = gender
    self.revision = revision
  }
}
