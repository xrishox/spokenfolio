import Foundation

struct WorkerRequest: Codable, Sendable {
  let id: UUID
  let text: String
  /// False hands the whole text to the private engine as ONE utterance so
  /// multi-sentence prosody flows; true (the default, and the HTTP path's
  /// behavior) synthesizes sentence by sentence.
  let splitSentences: Bool

  init(id: UUID, text: String, splitSentences: Bool = true) {
    self.id = id
    self.text = text
    self.splitSentences = splitSentences
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    text = try container.decode(String.self, forKey: .text)
    splitSentences = try container.decodeIfPresent(Bool.self, forKey: .splitSentences) ?? true
  }
}

struct WorkerResponseHeader: Codable, Sendable {
  let id: UUID
  let ok: Bool
  let pcmLength: Int
  let errorCode: String?
}

enum WorkerProtocolError: Error {
  case truncatedFrame
  case frameTooLarge
  case mismatchedResponse
  case invalidPayloadLength
}

enum WorkerFraming {
  static let maximumHeaderBytes = 64 * 1024
  static let maximumPCMBytes = 128 * 1024 * 1024

  static func readRequest(from handle: FileHandle) throws -> WorkerRequest? {
    guard let data = try readFrame(from: handle) else { return nil }
    return try JSONDecoder().decode(WorkerRequest.self, from: data)
  }

  static func validateRequest(text: String, splitSentences: Bool) throws {
    let request = WorkerRequest(id: UUID(), text: text, splitSentences: splitSentences)
    guard try JSONEncoder().encode(request).count <= maximumHeaderBytes else {
      throw WorkerProtocolError.frameTooLarge
    }
  }

  static func writeRequest(_ request: WorkerRequest, to handle: FileHandle) throws {
    try writeFrame(JSONEncoder().encode(request), to: handle)
  }

  static func readResponse(from handle: FileHandle, requestID: UUID) throws -> Data {
    guard let headerData = try readFrame(from: handle) else {
      throw WorkerProtocolError.truncatedFrame
    }
    let header = try JSONDecoder().decode(WorkerResponseHeader.self, from: headerData)
    guard header.id == requestID else { throw WorkerProtocolError.mismatchedResponse }
    guard header.pcmLength >= 0, header.pcmLength <= maximumPCMBytes else {
      throw WorkerProtocolError.invalidPayloadLength
    }
    if header.ok {
      guard header.errorCode == nil, header.pcmLength > 0,
        header.pcmLength.isMultiple(of: MemoryLayout<Int16>.size)
      else { throw WorkerProtocolError.invalidPayloadLength }
    } else {
      guard header.pcmLength == 0,
        let errorCode = header.errorCode,
        !errorCode.isEmpty
      else { throw WorkerProtocolError.invalidPayloadLength }
    }
    let pcm = try readExactly(header.pcmLength, from: handle) ?? Data()
    guard pcm.count == header.pcmLength else { throw WorkerProtocolError.truncatedFrame }
    if !header.ok {
      throw WorkerClientError.remote(header.errorCode!)
    }
    return pcm
  }

  static func writeResponse(
    requestID: UUID,
    pcm: Data = Data(),
    errorCode: String? = nil,
    to handle: FileHandle
  ) throws {
    if let errorCode {
      guard !errorCode.isEmpty, pcm.isEmpty else {
        throw WorkerProtocolError.invalidPayloadLength
      }
    } else {
      guard !pcm.isEmpty, pcm.count <= maximumPCMBytes,
        pcm.count.isMultiple(of: MemoryLayout<Int16>.size)
      else { throw WorkerProtocolError.invalidPayloadLength }
    }
    let header = WorkerResponseHeader(
      id: requestID,
      ok: errorCode == nil,
      pcmLength: pcm.count,
      errorCode: errorCode)
    try writeFrame(JSONEncoder().encode(header), to: handle)
    if !pcm.isEmpty { try handle.write(contentsOf: pcm) }
  }

  private static func readFrame(from handle: FileHandle) throws -> Data? {
    guard let prefix = try readExactly(4, from: handle) else { return nil }
    guard prefix.count == 4 else { throw WorkerProtocolError.truncatedFrame }
    let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length <= maximumHeaderBytes else { throw WorkerProtocolError.frameTooLarge }
    guard let data = try readExactly(Int(length), from: handle), data.count == Int(length) else {
      throw WorkerProtocolError.truncatedFrame
    }
    return data
  }

  private static func writeFrame(_ data: Data, to handle: FileHandle) throws {
    guard data.count <= maximumHeaderBytes else { throw WorkerProtocolError.frameTooLarge }
    var length = UInt32(data.count).bigEndian
    try withUnsafeBytes(of: &length) { try handle.write(contentsOf: Data($0)) }
    try handle.write(contentsOf: data)
  }

  private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
    if count == 0 { return Data() }
    var result = Data(capacity: count)
    while result.count < count {
      guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
        return result.isEmpty ? nil : result
      }
      result.append(chunk)
    }
    return result
  }
}
