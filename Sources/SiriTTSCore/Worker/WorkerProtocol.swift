import Foundation

struct WorkerRequest: Codable, Sendable {
  let id: UUID
  let text: String
  /// False hands the whole text to the private engine as ONE utterance so
  /// multi-sentence prosody flows; true (the default, and the HTTP path's
  /// behavior) synthesizes sentence by sentence.
  let splitSentences: Bool
  /// Ask for the engine's word timings as a third response frame. Only the
  /// unsplit audiobook path sets this; absent in old peers.
  let includeTimings: Bool

  init(id: UUID, text: String, splitSentences: Bool = true, includeTimings: Bool = false) {
    self.id = id
    self.text = text
    self.splitSentences = splitSentences
    self.includeTimings = includeTimings
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    text = try container.decode(String.self, forKey: .text)
    splitSentences = try container.decodeIfPresent(Bool.self, forKey: .splitSentences) ?? true
    includeTimings = try container.decodeIfPresent(Bool.self, forKey: .includeTimings) ?? false
  }
}

struct WorkerResponseHeader: Codable, Sendable {
  let id: UUID
  let ok: Bool
  let pcmLength: Int
  let errorCode: String?
  /// Byte length of the raw timings frame that follows the PCM, when the
  /// request asked for timings. Absent/nil in old peers.
  let timingsLength: Int?

  init(id: UUID, ok: Bool, pcmLength: Int, errorCode: String?, timingsLength: Int? = nil) {
    self.id = id
    self.ok = ok
    self.pcmLength = pcmLength
    self.errorCode = errorCode
    self.timingsLength = timingsLength
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    ok = try container.decode(Bool.self, forKey: .ok)
    pcmLength = try container.decode(Int.self, forKey: .pcmLength)
    errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
    timingsLength = try container.decodeIfPresent(Int.self, forKey: .timingsLength)
  }
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
  static let maximumTimingsBytes = 16 * 1024 * 1024

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
    try readDetailedResponse(from: handle, requestID: requestID).pcm
  }

  static func readDetailedResponse(
    from handle: FileHandle, requestID: UUID
  ) throws -> (pcm: Data, timingsJSON: Data?) {
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
    var timingsJSON: Data?
    if let timingsLength = header.timingsLength {
      guard timingsLength > 0, timingsLength <= maximumTimingsBytes else {
        throw WorkerProtocolError.invalidPayloadLength
      }
      let payload = try readExactly(timingsLength, from: handle) ?? Data()
      guard payload.count == timingsLength else { throw WorkerProtocolError.truncatedFrame }
      timingsJSON = payload
    }
    if !header.ok {
      throw WorkerClientError.remote(header.errorCode!)
    }
    return (pcm, timingsJSON)
  }

  static func writeResponse(
    requestID: UUID,
    pcm: Data = Data(),
    errorCode: String? = nil,
    timingsJSON: Data? = nil,
    to handle: FileHandle
  ) throws {
    if let errorCode {
      guard !errorCode.isEmpty, pcm.isEmpty, timingsJSON == nil else {
        throw WorkerProtocolError.invalidPayloadLength
      }
    } else {
      guard !pcm.isEmpty, pcm.count <= maximumPCMBytes,
        pcm.count.isMultiple(of: MemoryLayout<Int16>.size)
      else { throw WorkerProtocolError.invalidPayloadLength }
    }
    if let timingsJSON {
      guard !timingsJSON.isEmpty, timingsJSON.count <= maximumTimingsBytes else {
        throw WorkerProtocolError.invalidPayloadLength
      }
    }
    let header = WorkerResponseHeader(
      id: requestID,
      ok: errorCode == nil,
      pcmLength: pcm.count,
      errorCode: errorCode,
      timingsLength: timingsJSON?.count)
    try writeFrame(JSONEncoder().encode(header), to: handle)
    if !pcm.isEmpty { try handle.write(contentsOf: pcm) }
    if let timingsJSON { try handle.write(contentsOf: timingsJSON) }
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
