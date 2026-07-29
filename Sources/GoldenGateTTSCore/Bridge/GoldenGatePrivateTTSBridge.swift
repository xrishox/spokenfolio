import AudioToolbox
import Darwin
import Foundation
import ObjectiveC
import TTSKit

private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
private typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int64
private typealias DoubleGetter = @convention(c) (AnyObject, Selector) -> Double
private typealias ASBDGetter =
  @convention(c) (AnyObject, Selector) -> AudioStreamBasicDescription
private typealias ObjectSetter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
private typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
private typealias FloatSetter = @convention(c) (AnyObject, Selector, Float) -> Void
private typealias IntegerSetter = @convention(c) (AnyObject, Selector, Int64) -> Void
private typealias TwoObjectCall =
  @convention(c) (AnyObject, Selector, AnyObject?, AnyObject) -> Void
private typealias RequestInitializer =
  @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Unmanaged<AnyObject>?
private typealias VoicesReply = @convention(block) (NSArray) -> Void
private typealias AudioReply = @convention(block) (NSObject) -> Void
private typealias ObjectReply = @convention(block) (NSObject?) -> Void

private final class LockedSynthesisState: @unchecked Sendable {
  let lock = NSLock()
  var pcm = Data()
  var packetDescriptions: [AudioStreamPacketDescription] = []
  var format: AudioStreamBasicDescription?
  var failure: String?
  var instrumentation: GoldenGateInstrumentation?
  var timings: [SpokenWordTiming] = []
  var finishError: String?
}

package final class GoldenGateVoiceHandle {
  package let descriptor: GoldenGateVoice
  fileprivate let object: NSObject

  package init(descriptor: GoldenGateVoice, object: NSObject) {
    self.descriptor = descriptor
    self.object = object
  }
}

package protocol GoldenGateSynthesisRuntime: AnyObject {
  func voices() throws -> [GoldenGateVoiceHandle]
  func synthesize(
    text: String, voice: GoldenGateVoiceHandle, pace: Int, expressivity: Int
  ) throws -> (
    audio: PCM16Audio, instrumentation: GoldenGateInstrumentation,
    timings: [SpokenWordTiming]
  )
}

/// Dynamic, fail-closed access to Golden Gate's high-level Siri daemon API.
/// This type is constructed only by one-shot catalog children and synthesis
/// workers; the gateway process never loads the private framework.
package final class GoldenGatePrivateTTSRuntime: GoldenGateSynthesisRuntime, @unchecked Sendable {
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService"
  private static let maximumPCMBytes = 128 << 20

  private let frameworkHandle: UnsafeMutableRawPointer
  private let session: NSObject
  private let voiceClass: NSObject.Type
  private let requestClass: NSObject.Type
  private let downloadedVoices: TwoObjectCall
  private let synthesize: TwoObjectCall
  private let requestInitializer: RequestInitializer

  private let voicesSelector = NSSelectorFromString("downloadedVoicesMatching:reply:")
  private let synthesizeSelector = NSSelectorFromString("synthesizeWithRequest:didFinish:")
  private let requestInitSelector = NSSelectorFromString("initWithText:voice:")

  package init() throws {
    guard #available(macOS 27, *) else { throw TTSBackendError.unavailable }
    guard let handle = dlopen(Self.frameworkPath, RTLD_NOW | RTLD_LOCAL) else {
      throw GoldenGateTTSError.frameworkUnavailable(
        dlerror().map { String(cString: $0) } ?? "unknown dlopen error")
    }
    frameworkHandle = handle

    guard let sessionClass = NSClassFromString("SiriTTSDaemonSession") as? NSObject.Type,
      let resolvedVoiceClass = NSClassFromString("SiriTTSSynthesisVoice") as? NSObject.Type,
      let resolvedRequestClass = NSClassFromString("SiriTTSSynthesisRequest") as? NSObject.Type
    else { throw GoldenGateTTSError.privateABIChanged("required daemon classes are missing") }
    session = sessionClass.init()
    voiceClass = resolvedVoiceClass
    requestClass = resolvedRequestClass

    let voicesMethod = try Self.requireMethod(
      on: sessionClass, selector: voicesSelector, encoding: "v32@0:8@16@?24")
    let synthesizeMethod = try Self.requireMethod(
      on: sessionClass, selector: synthesizeSelector, encoding: "v32@0:8@16@?24")
    let initMethod = try Self.requireMethod(
      on: resolvedRequestClass, selector: requestInitSelector,
      encoding: "@32@0:8@16@24")

    for (name, encoding) in [
      ("setPrivacySensitive:", "v20@0:8B16"),
      ("setRate:", "v20@0:8f16"),
      ("setPitch:", "v20@0:8f16"),
      ("setVolume:", "v20@0:8f16"),
      ("setSynthesisProfile:", "v24@0:8q16"),
      ("setDisableCompactVoice:", "v20@0:8B16"),
      ("setOptInNextGenVoice:", "v20@0:8B16"),
      ("setVoicePacePreset:", "v24@0:8q16"),
      ("setVoiceExpressivityPreset:", "v24@0:8q16"),
      ("setDidGenerateAudio:", "v24@0:8@?16"),
      ("setDidGenerateWordTimings:", "v24@0:8@?16"),
      ("setDidReportInstrument:", "v24@0:8@?16"),
    ] {
      _ = try Self.requireMethod(
        on: resolvedRequestClass, selector: NSSelectorFromString(name), encoding: encoding)
    }
    for (name, encoding) in [
      ("type", "q16@0:8"), ("gender", "q16@0:8"),
      ("footprint", "q16@0:8"), ("version", "q16@0:8"),
      ("name", "@16@0:8"), ("language", "@16@0:8"),
    ] {
      _ = try Self.requireMethod(
        on: resolvedVoiceClass, selector: NSSelectorFromString(name), encoding: encoding)
    }

    downloadedVoices = unsafeBitCast(
      method_getImplementation(voicesMethod), to: TwoObjectCall.self)
    synthesize = unsafeBitCast(
      method_getImplementation(synthesizeMethod), to: TwoObjectCall.self)
    requestInitializer = unsafeBitCast(
      method_getImplementation(initMethod), to: RequestInitializer.self)
  }

  deinit { dlclose(frameworkHandle) }

  package func voices() throws -> [GoldenGateVoiceHandle] {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var objects: [NSObject] = []
    let reply: VoicesReply = { values in
      lock.lock()
      objects = values.compactMap { $0 as? NSObject }
      lock.unlock()
      semaphore.signal()
    }
    downloadedVoices(session, voicesSelector, nil, reply as AnyObject)
    guard semaphore.wait(timeout: .now() + 15) == .success else {
      throw GoldenGateTTSError.catalogUnavailable("daemon enumeration timed out")
    }
    lock.lock()
    let snapshot = objects
    lock.unlock()

    let filtered = try snapshot.compactMap { object -> GoldenGateVoiceHandle? in
      guard object.isKind(of: voiceClass), try Self.integer(object, "type") == 7 else { return nil }
      guard let id = try Self.string(object, "name"),
        let language = try Self.string(object, "language"),
        !id.isEmpty, !language.isEmpty
      else { return nil }
      let gender = Int(try Self.integer(object, "gender"))
      let footprint = try Self.integer(object, "footprint")
      let version = try Self.integer(object, "version")
      let displayName: String = switch id {
      case "en-US-F": "American Voice 7"
      case "en-US-G": "American Voice 6"
      default: id
      }
      return GoldenGateVoiceHandle(
        descriptor: GoldenGateVoice(
          id: id, name: displayName, language: language,
          quality: footprint == 2 ? "premium" : "enhanced",
          gender: gender, revision: String(version)),
        object: object)
    }
    guard !filtered.isEmpty else {
      throw GoldenGateTTSError.catalogUnavailable("no downloaded fmvoice entries")
    }
    return filtered
  }

  package func synthesize(
    text: String, voice: GoldenGateVoiceHandle, pace: Int, expressivity: Int
  ) throws -> (
    audio: PCM16Audio, instrumentation: GoldenGateInstrumentation,
    timings: [SpokenWordTiming]
  ) {
    guard !text.isEmpty else { throw TTSBackendError.invalidInput("Text must be non-empty.") }
    let voiceID = voice.descriptor.id

    guard let allocation = requestClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
    else { throw GoldenGateTTSError.privateABIChanged("request allocation failed") }
    guard let request = requestInitializer(
      allocation, requestInitSelector, text as NSString, voice.object
    )?.takeRetainedValue() as? NSObject
    else { throw GoldenGateTTSError.privateABIChanged("request initialization failed") }

    Self.setBool(request, "setPrivacySensitive:", true)
    Self.setFloat(request, "setRate:", 1)
    Self.setFloat(request, "setPitch:", 1)
    Self.setFloat(request, "setVolume:", 1)
    Self.setInteger(request, "setSynthesisProfile:", 1)
    Self.setBool(request, "setDisableCompactVoice:", true)
    Self.setBool(request, "setOptInNextGenVoice:", true)
    Self.setInteger(request, "setVoicePacePreset:", Int64(pace))
    Self.setInteger(request, "setVoiceExpressivityPreset:", Int64(expressivity))

    let state = LockedSynthesisState()
    let audioReply: AudioReply = { audio in
      state.lock.lock()
      defer { state.lock.unlock() }
      guard state.failure == nil else { return }
      do {
        let format = try Self.asbd(audio)
        let chunk = try Self.data(audio, "audioData")
        let isFloatPCM = format.mFormatID == kAudioFormatLinearPCM
          && format.mBitsPerChannel == 32
          && format.mSampleRate > 0
          && format.mChannelsPerFrame > 0
          && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
          && format.mBytesPerFrame == 4 * format.mChannelsPerFrame
          && format.mBytesPerPacket == format.mBytesPerFrame
          && format.mFramesPerPacket == 1
        let isOpus = format.mFormatID == kAudioFormatOpus
          && format.mSampleRate > 0 && format.mChannelsPerFrame > 0
        guard isFloatPCM || isOpus else {
          state.failure = "unsupported callback ASBD rate=\(format.mSampleRate) format=\(format.mFormatID) flags=\(format.mFormatFlags)"
          return
        }
        if let prior = state.format,
          prior.mSampleRate != format.mSampleRate
            || prior.mFormatID != format.mFormatID
            || prior.mFormatFlags != format.mFormatFlags
            || prior.mChannelsPerFrame != format.mChannelsPerFrame
            || prior.mBitsPerChannel != format.mBitsPerChannel
        {
          state.failure = "audio format changed during synthesis"
          return
        }
        guard chunk.count <= Self.maximumPCMBytes - state.pcm.count else {
          state.failure = "audio exceeded the 128 MiB safety limit"
          return
        }
        if isOpus {
          let packetData = try Self.data(audio, "packetDescriptions")
          var descriptions = try Self.packetDescriptions(packetData)
          let baseOffset = Int64(state.pcm.count)
          for index in descriptions.indices {
            descriptions[index].mStartOffset += baseOffset
          }
          state.packetDescriptions.append(contentsOf: descriptions)
        }
        state.format = format
        state.pcm.append(chunk)
      } catch {
        state.failure = error.localizedDescription
      }
    }
    let timingsReply: ObjectReply = { value in
      guard let values = value as? NSArray else {
        state.lock.lock()
        state.failure = "word timing callback payload was not an array"
        state.lock.unlock()
        return
      }
      state.lock.lock()
      defer { state.lock.unlock() }
      guard state.failure == nil else { return }
      do {
        guard values.count <= 16_384 - state.timings.count else {
          throw SpokenWordTimingValidationError.tooMany(state.timings.count + values.count)
        }
        for case let element as NSObject in values {
          let start = try Self.double(element, "startTime")
          let rangeObject = try Self.requiredObject(element, "textRange")
          guard let rangeValue = rangeObject as? NSValue else {
            throw GoldenGateTTSError.privateABIChanged("textRange was not NSValue")
          }
          let range = rangeValue.rangeValue
          guard range.location != NSNotFound else {
            throw SpokenWordTimingValidationError.invalidRange(index: state.timings.count)
          }
          state.timings.append(
            SpokenWordTiming(
              utf16Offset: range.location, utf16Length: range.length,
              startSeconds: start))
        }
      } catch {
        state.failure = error.localizedDescription
      }
    }
    let metricsReply: ObjectReply = { value in
      guard let metrics = value else { return }
      state.lock.lock()
      defer { state.lock.unlock() }
      do {
        state.instrumentation = try Self.instrumentation(metrics)
      } catch {
        state.failure = error.localizedDescription
      }
    }
    Self.setObject(request, "setDidGenerateAudio:", audioReply as AnyObject)
    Self.setObject(request, "setDidGenerateWordTimings:", timingsReply as AnyObject)
    Self.setObject(request, "setDidReportInstrument:", metricsReply as AnyObject)

    let done = DispatchSemaphore(value: 0)
    let finishReply: ObjectReply = { value in
      state.lock.lock()
      if let error = value as? NSError { state.finishError = error.localizedDescription }
      state.lock.unlock()
      done.signal()
    }
    synthesize(session, synthesizeSelector, request, finishReply as AnyObject)
    guard done.wait(timeout: .now() + 120) == .success else {
      throw GoldenGateTTSError.synthesisFailed("daemon request timed out")
    }
    _ = (audioReply, timingsReply, metricsReply, finishReply)

    state.lock.lock()
    let pcm = state.pcm
    let packetDescriptions = state.packetDescriptions
    let format = state.format
    let failure = state.failure
    let finishError = state.finishError
    let instrumentation = state.instrumentation
    let timings = state.timings
    state.lock.unlock()

    if let finishError { throw GoldenGateTTSError.synthesisFailed(finishError) }
    if let failure { throw GoldenGateTTSError.unsupportedAudioFormat(failure) }
    guard let format, !pcm.isEmpty else { throw GoldenGateTTSError.noAudioProduced }
    guard let instrumentation else {
      throw GoldenGateTTSError.invalidInstrumentation("instrumentation callback was missing")
    }
    try instrumentation.validate(
      voiceID: voiceID, pace: pace, expressivity: expressivity,
      allowsCachedAdapter: format.mFormatID == kAudioFormatOpus)
    let converted: PCM16Audio
    if format.mFormatID == kAudioFormatLinearPCM {
      converted = try GoldenGateAudioDecoder.convertFloat32PCM(
        pcm, sampleRate: Int(format.mSampleRate), channels: Int(format.mChannelsPerFrame))
    } else if format.mFormatID == kAudioFormatOpus {
      converted = try GoldenGateAudioDecoder.decodeOpus(
        pcm, packetDescriptions: packetDescriptions, format: format)
    } else {
      throw GoldenGateTTSError.unsupportedAudioFormat("unsupported final ASBD")
    }
    let frameCount =
      converted.data.count / (MemoryLayout<Int16>.size * converted.channels)
    let validatedTimings = try SpokenWordTimingValidator.validate(
      timings, text: text,
      audioDuration: Double(frameCount) / Double(converted.sampleRate))
    return (converted, instrumentation, validatedTimings)
  }

  private static func instrumentation(_ object: NSObject) throws -> GoldenGateInstrumentation {
    let voice = try requiredObject(object, "voice")
    let resource = try requiredObject(object, "resource")
    guard let voiceID = try string(voice, "name") else {
      throw GoldenGateTTSError.invalidInstrumentation("voice name missing")
    }
    let voiceType = Int(try integer(voice, "type"))
    let resourceIdentity =
      (try? string(resource, "language")) ?? resource.description
    let resourceRevision = String(try integer(resource, "version"))
    let errorCode = Int(try integer(object, "errorCode"))
    let pace = try presetNumber(object, "voicePacePreset", prefix: "pace")
    let expressivity = try presetNumber(
      object, "voiceExpressivityPreset", prefix: "expressivity")
    let adapter = try string(object, "afmAdapterBundleId") ?? ""
    let duration = try double(object, "audioDuration")
    return GoldenGateInstrumentation(
      voiceID: voiceID,
      voiceType: voiceType,
      resourceIdentity: resourceIdentity,
      resourceRevision: resourceRevision,
      errorCode: errorCode,
      pacePreset: pace,
      expressivityPreset: expressivity,
      adapterID: adapter,
      audioDuration: duration)
  }

  private static func presetNumber(
    _ object: NSObject, _ name: String, prefix: String
  ) throws -> Int {
    let value = try requiredObject(object, name)
    if let number = value as? NSNumber { return number.intValue }
    let description = value.description.lowercased()
    guard let suffix = description.split(separator: prefix).last,
      let number = Int(suffix.trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw GoldenGateTTSError.invalidInstrumentation("\(name) was unreadable") }
    return number
  }

  private static func requireMethod(
    on cls: AnyClass, selector: Selector, encoding expected: String
  ) throws -> Method {
    guard let method = class_getInstanceMethod(cls, selector),
      let typeEncoding = method_getTypeEncoding(method)
    else {
      throw GoldenGateTTSError.privateABIChanged(
        "missing selector \(NSStringFromSelector(selector))")
    }
    let actual = String(cString: typeEncoding)
    guard actual == expected else {
      throw GoldenGateTTSError.privateABIChanged(
        "\(NSStringFromSelector(selector)) has encoding \(actual), expected \(expected)")
    }
    return method
  }

  private static func method(_ object: NSObject, _ name: String) throws -> Method {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(type(of: object), selector) else {
      throw GoldenGateTTSError.privateABIChanged("missing callback selector \(name)")
    }
    return method
  }

  private static func requiredObject(_ object: NSObject, _ name: String) throws -> NSObject {
    guard let value = try objectValue(object, name) as? NSObject else {
      throw GoldenGateTTSError.privateABIChanged("\(name) returned no object")
    }
    return value
  }

  private static func objectValue(_ object: NSObject, _ name: String) throws -> AnyObject? {
    let method = try method(object, name)
    let getter = unsafeBitCast(method_getImplementation(method), to: ObjectGetter.self)
    return getter(object, NSSelectorFromString(name))?.takeUnretainedValue()
  }

  private static func string(_ object: NSObject, _ name: String) throws -> String? {
    (try objectValue(object, name) as? NSString).map(String.init)
  }

  private static func data(_ object: NSObject, _ name: String) throws -> Data {
    guard let value = try objectValue(object, name) as? NSData else {
      throw GoldenGateTTSError.privateABIChanged("\(name) did not return NSData")
    }
    return value as Data
  }

  private static func packetDescriptions(
    _ data: Data
  ) throws -> [AudioStreamPacketDescription] {
    let size = MemoryLayout<AudioStreamPacketDescription>.size
    guard !data.isEmpty, data.count.isMultiple(of: size) else {
      throw GoldenGateTTSError.unsupportedAudioFormat("invalid Opus packet descriptions")
    }
    return data.withUnsafeBytes { raw in
      stride(from: 0, to: raw.count, by: size).map {
        raw.loadUnaligned(fromByteOffset: $0, as: AudioStreamPacketDescription.self)
      }
    }
  }

  private static func integer(_ object: NSObject, _ name: String) throws -> Int64 {
    let method = try method(object, name)
    let getter = unsafeBitCast(method_getImplementation(method), to: IntegerGetter.self)
    return getter(object, NSSelectorFromString(name))
  }

  private static func double(_ object: NSObject, _ name: String) throws -> Double {
    let method = try method(object, name)
    guard let typeEncoding = method_getTypeEncoding(method) else {
      throw GoldenGateTTSError.privateABIChanged("\(name) has no type encoding")
    }
    let encoding = String(cString: typeEncoding)
    if encoding.hasPrefix("d") {
      let getter = unsafeBitCast(method_getImplementation(method), to: DoubleGetter.self)
      return getter(object, NSSelectorFromString(name))
    }
    if let number = try objectValue(object, name) as? NSNumber { return number.doubleValue }
    throw GoldenGateTTSError.privateABIChanged("\(name) did not return a number")
  }

  private static func asbd(_ object: NSObject) throws -> AudioStreamBasicDescription {
    let method = try method(object, "asbd")
    guard let encoding = method_getTypeEncoding(method),
      String(cString: encoding).hasPrefix("{AudioStreamBasicDescription=")
    else { throw GoldenGateTTSError.privateABIChanged("audio asbd encoding changed") }
    let getter = unsafeBitCast(method_getImplementation(method), to: ASBDGetter.self)
    return getter(object, NSSelectorFromString("asbd"))
  }

  private static func setObject(_ object: NSObject, _ name: String, _ value: AnyObject) {
    let selector = NSSelectorFromString(name)
    let method = class_getInstanceMethod(type(of: object), selector)!
    let setter = unsafeBitCast(method_getImplementation(method), to: ObjectSetter.self)
    setter(object, selector, value)
  }

  private static func setBool(_ object: NSObject, _ name: String, _ value: Bool) {
    let selector = NSSelectorFromString(name)
    let method = class_getInstanceMethod(type(of: object), selector)!
    let setter = unsafeBitCast(method_getImplementation(method), to: BoolSetter.self)
    setter(object, selector, value)
  }

  private static func setFloat(_ object: NSObject, _ name: String, _ value: Float) {
    let selector = NSSelectorFromString(name)
    let method = class_getInstanceMethod(type(of: object), selector)!
    let setter = unsafeBitCast(method_getImplementation(method), to: FloatSetter.self)
    setter(object, selector, value)
  }

  private static func setInteger(_ object: NSObject, _ name: String, _ value: Int64) {
    let selector = NSSelectorFromString(name)
    let method = class_getInstanceMethod(type(of: object), selector)!
    let setter = unsafeBitCast(method_getImplementation(method), to: IntegerSetter.self)
    setter(object, selector, value)
  }

}
