import Foundation
import TTSKit

package struct LocalTTSWorkerRequest: Codable, Hashable, Sendable {
  package let id: UUID
  package let request: TTSSynthesisRequest

  package var text: String { request.text }
  package var selection: TTSVoiceSelection { request.selection }
  package var utteranceMode: TTSUtteranceMode { request.utteranceMode }
  package var splitSentences: Bool { request.utteranceMode == .sentenceSequence }
  package var includeTimings: Bool { request.includeTimings }

  package init(id: UUID = UUID(), request: TTSSynthesisRequest) {
    self.id = id
    self.request = request
  }
}

package struct LocalTTSWorkerResponseHeader: Codable, Sendable {
  package let id: UUID
  package let ok: Bool
  package let pcmLength: Int
  package let sampleRate: Int
  package let channels: Int
  package let errorCode: String?
  package let timingsLength: Int?
  package let provenanceLength: Int?

  package init(
    id: UUID, ok: Bool, pcmLength: Int,
    sampleRate: Int = 48_000, channels: Int = 1,
    errorCode: String?, timingsLength: Int? = nil,
    provenanceLength: Int? = nil
  ) {
    self.id = id
    self.ok = ok
    self.pcmLength = pcmLength
    self.sampleRate = sampleRate
    self.channels = channels
    self.errorCode = errorCode
    self.timingsLength = timingsLength
    self.provenanceLength = provenanceLength
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    ok = try container.decode(Bool.self, forKey: .ok)
    pcmLength = try container.decode(Int.self, forKey: .pcmLength)
    sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48_000
    channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 1
    errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
    timingsLength = try container.decodeIfPresent(Int.self, forKey: .timingsLength)
    provenanceLength = try container.decodeIfPresent(Int.self, forKey: .provenanceLength)
  }
}

package struct LocalTTSWorkerResult: Sendable, Equatable {
  package let audio: PCM16Audio
  package let timings: [SpokenWordTiming]?
  package let provenance: TTSRuntimeProvenance?

  package init(
    audio: PCM16Audio, timings: [SpokenWordTiming]? = nil,
    provenance: TTSRuntimeProvenance? = nil
  ) {
    self.audio = audio
    self.timings = timings
    self.provenance = provenance
  }
}

package enum LocalTTSWorkerProtocolError: Error, Sendable {
  case truncatedFrame
  case frameTooLarge
  case mismatchedResponse
  case invalidPayloadLength
}

package enum LocalTTSWorkerFraming {
  package static let maximumHeaderBytes = 64 * 1024
  package static let maximumPCMBytes = 128 * 1024 * 1024
  package static let maximumTimingsBytes = 16 * 1024 * 1024
  package static let maximumProvenanceBytes = 64 * 1024

  package static func readRequest(from handle: FileHandle) throws -> LocalTTSWorkerRequest? {
    guard let data = try readFrame(from: handle) else { return nil }
    return try JSONDecoder().decode(LocalTTSWorkerRequest.self, from: data)
  }

  package static func validateRequest(_ request: LocalTTSWorkerRequest) throws {
    guard try JSONEncoder().encode(request).count <= maximumHeaderBytes else {
      throw LocalTTSWorkerProtocolError.frameTooLarge
    }
  }

  package static func writeRequest(
    _ request: LocalTTSWorkerRequest, to handle: FileHandle
  ) throws {
    try validateRequest(request)
    try writeFrame(JSONEncoder().encode(request), to: handle)
  }

  package static func readResponse(
    from handle: FileHandle, requestID: UUID
  ) throws -> Data {
    try readDetailedResponse(from: handle, requestID: requestID).audio.data
  }

  package static func readDetailedResponse(
    from handle: FileHandle, requestID: UUID
  ) throws -> LocalTTSWorkerResult {
    guard let headerData = try readFrame(from: handle) else {
      throw LocalTTSWorkerProtocolError.truncatedFrame
    }
    let header = try JSONDecoder().decode(LocalTTSWorkerResponseHeader.self, from: headerData)
    guard header.id == requestID else { throw LocalTTSWorkerProtocolError.mismatchedResponse }
    guard header.pcmLength >= 0, header.pcmLength <= maximumPCMBytes else {
      throw LocalTTSWorkerProtocolError.invalidPayloadLength
    }
    if header.ok {
      guard header.errorCode == nil, header.pcmLength > 0,
        header.sampleRate > 0, header.channels > 0
      else { throw LocalTTSWorkerProtocolError.invalidPayloadLength }
    } else {
      guard header.pcmLength == 0,
        let errorCode = header.errorCode, !errorCode.isEmpty,
        header.timingsLength == nil, header.provenanceLength == nil
      else { throw LocalTTSWorkerProtocolError.invalidPayloadLength }
    }
    let pcm = try readExactly(header.pcmLength, from: handle) ?? Data()
    guard pcm.count == header.pcmLength else {
      throw LocalTTSWorkerProtocolError.truncatedFrame
    }
    guard header.ok else { throw LocalTTSWorkerClientError.remote(header.errorCode!) }
    let audio: PCM16Audio
    do {
      audio = try PCM16Audio(
        data: pcm, sampleRate: header.sampleRate, channels: header.channels)
    } catch {
      throw LocalTTSWorkerProtocolError.invalidPayloadLength
    }

    var timings: [SpokenWordTiming]?
    if let length = header.timingsLength {
      guard length > 0, length <= maximumTimingsBytes else {
        throw LocalTTSWorkerProtocolError.invalidPayloadLength
      }
      let payload = try readExactly(length, from: handle) ?? Data()
      guard payload.count == length else { throw LocalTTSWorkerProtocolError.truncatedFrame }
      timings = try JSONDecoder().decode([SpokenWordTiming].self, from: payload)
    }

    var provenance: TTSRuntimeProvenance?
    if let length = header.provenanceLength {
      guard length > 0, length <= maximumProvenanceBytes else {
        throw LocalTTSWorkerProtocolError.invalidPayloadLength
      }
      let payload = try readExactly(length, from: handle) ?? Data()
      guard payload.count == length else { throw LocalTTSWorkerProtocolError.truncatedFrame }
      provenance = try JSONDecoder().decode(TTSRuntimeProvenance.self, from: payload)
    }
    return LocalTTSWorkerResult(audio: audio, timings: timings, provenance: provenance)
  }

  package static func writeResponse(
    requestID: UUID, audio: PCM16Audio? = nil,
    errorCode: String? = nil, timings: [SpokenWordTiming]? = nil,
    provenance: TTSRuntimeProvenance? = nil, to handle: FileHandle
  ) throws {
    let pcm = audio?.data ?? Data()
    let timingsJSON = try timings.map { try JSONEncoder().encode($0) }
    let provenanceJSON = try provenance.map { try JSONEncoder().encode($0) }
    if let errorCode {
      guard !errorCode.isEmpty, audio == nil, timingsJSON == nil, provenanceJSON == nil else {
        throw LocalTTSWorkerProtocolError.invalidPayloadLength
      }
    } else {
      guard let audio, pcm.count <= maximumPCMBytes else {
        throw LocalTTSWorkerProtocolError.invalidPayloadLength
      }
      _ = audio
    }
    if let timingsJSON {
      guard !timingsJSON.isEmpty, timingsJSON.count <= maximumTimingsBytes else {
        throw LocalTTSWorkerProtocolError.invalidPayloadLength
      }
    }
    if let provenanceJSON {
      guard !provenanceJSON.isEmpty, provenanceJSON.count <= maximumProvenanceBytes else {
        throw LocalTTSWorkerProtocolError.invalidPayloadLength
      }
    }
    let header = LocalTTSWorkerResponseHeader(
      id: requestID, ok: errorCode == nil, pcmLength: pcm.count,
      sampleRate: audio?.sampleRate ?? 48_000,
      channels: audio?.channels ?? 1,
      errorCode: errorCode, timingsLength: timingsJSON?.count,
      provenanceLength: provenanceJSON?.count)
    try writeFrame(JSONEncoder().encode(header), to: handle)
    if !pcm.isEmpty { try handle.write(contentsOf: pcm) }
    if let timingsJSON { try handle.write(contentsOf: timingsJSON) }
    if let provenanceJSON { try handle.write(contentsOf: provenanceJSON) }
  }

  package static func writeResponse(
    requestID: UUID, pcm: Data = Data(), errorCode: String? = nil,
    timingsJSON: Data? = nil, to handle: FileHandle
  ) throws {
    let audio = pcm.isEmpty ? nil : try PCM16Audio(data: pcm, sampleRate: 48_000, channels: 1)
    let timings = try timingsJSON.map {
      try JSONDecoder().decode([SpokenWordTiming].self, from: $0)
    }
    try writeResponse(
      requestID: requestID, audio: audio, errorCode: errorCode,
      timings: timings, to: handle)
  }

  private static func readFrame(from handle: FileHandle) throws -> Data? {
    guard let prefix = try readExactly(4, from: handle) else { return nil }
    guard prefix.count == 4 else { throw LocalTTSWorkerProtocolError.truncatedFrame }
    let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length <= maximumHeaderBytes else { throw LocalTTSWorkerProtocolError.frameTooLarge }
    guard let data = try readExactly(Int(length), from: handle), data.count == Int(length) else {
      throw LocalTTSWorkerProtocolError.truncatedFrame
    }
    return data
  }

  private static func writeFrame(_ data: Data, to handle: FileHandle) throws {
    guard data.count <= maximumHeaderBytes else {
      throw LocalTTSWorkerProtocolError.frameTooLarge
    }
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
