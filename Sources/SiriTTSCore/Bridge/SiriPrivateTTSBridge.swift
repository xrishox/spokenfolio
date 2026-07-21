import AudioToolbox
import Darwin
import Foundation
import ObjectiveC

private typealias SiriAudioHandler = @convention(block) (NSData) -> Void
private typealias SiriWordTimingsHandler = @convention(block) ([NSObject]) -> Void
private typealias SiriDynamicPromptHandler = @convention(block) (AnyObject?) -> Void

/// Dynamically resolves the private SiriTTSService ABI. Keeping every private
/// symbol behind this boundary lets startup fail cleanly if Apple changes it.
final class SiriPrivateTTSRuntime: @unchecked Sendable {
  typealias EngineInit =
    @convention(c) (
      AnyObject, Selector, AnyObject, AnyObject, UnsafeMutablePointer<NSObject?>?
    ) -> NSObject?
  typealias Preheat =
    @convention(c) (
      AnyObject, Selector, UnsafeMutablePointer<AnyObject?>
    ) -> Bool
  typealias Synthesize =
    @convention(c) (
      AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSObject?>?
    ) -> Bool
  typealias Stop = @convention(c) (AnyObject, Selector) -> Void
  typealias GetASBD = @convention(c) (AnyObject, Selector) -> AudioStreamBasicDescription

  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService"

  private let frameworkHandle: UnsafeMutableRawPointer
  private let engineClass: NSObject.Type
  private let requestClass: NSObject.Type
  private let initSelector = NSSelectorFromString("initWithVoicePath:resourcePath:error:")
  private let preheatSelector = NSSelectorFromString("preheatWithError:")
  private let synthesizeSelector = NSSelectorFromString("synthesize:error:")
  private let stopSelector = NSSelectorFromString("stopSynthesis")
  private let asbdSelector = NSSelectorFromString("asbd")
  private let engineInit: EngineInit
  private let preheat: Preheat
  private let synthesize: Synthesize
  private let stopSynthesis: Stop
  private let getASBD: GetASBD

  init() throws {
    guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
      throw SiriTTSError.frameworkUnavailable(
        dlerror().map { String(cString: $0) } ?? "unknown dlopen error")
    }
    frameworkHandle = handle

    guard
      let resolvedEngineClass = NSClassFromString("SiriTTSSynthesisEngine")
        as? NSObject.Type,
      let resolvedRequestClass = NSClassFromString("SiriTTSSynthesisEngineRequest")
        as? NSObject.Type
    else {
      throw SiriTTSError.privateABIChanged("required classes are missing")
    }
    engineClass = resolvedEngineClass
    requestClass = resolvedRequestClass

    let initMethod = try Self.requireMethod(
      on: resolvedEngineClass, selector: initSelector,
      encoding: "@40@0:8@16@24^@32")
    let preheatMethod = try Self.requireMethod(
      on: resolvedEngineClass, selector: preheatSelector,
      encoding: "B24@0:8^@16")
    let synthesizeMethod = try Self.requireMethod(
      on: resolvedEngineClass, selector: synthesizeSelector,
      encoding: "B32@0:8@16^@24")
    let stopMethod = try Self.requireMethod(
      on: resolvedEngineClass, selector: stopSelector, encoding: "v16@0:8")
    let asbdMethod = try Self.requireMethod(
      on: resolvedEngineClass,
      selector: asbdSelector,
      encoding: "{AudioStreamBasicDescription=dIIIIIIII}16@0:8")

    for (name, encoding) in [
      ("setAudioHandler:", "v24@0:8@?16"),
      ("setWordTimingsHandler:", "v24@0:8@?16"),
      ("setDynamicPromptHandler:", "v24@0:8@?16"),
      ("setPromptStyle:", "v24@0:8@16"),
    ] {
      _ = try Self.requireMethod(
        on: resolvedRequestClass,
        selector: NSSelectorFromString(name),
        encoding: encoding)
    }
    try Self.requireSetter(on: resolvedRequestClass, name: "setText:", acceptedTypes: ["@"])
    try Self.requireSetter(
      on: resolvedRequestClass, name: "setPrivacySensitive:", acceptedTypes: ["B", "c"])
    try Self.requireSetter(on: resolvedRequestClass, name: "setRequestId:", acceptedTypes: ["@"])
    try Self.requireSetter(
      on: resolvedRequestClass, name: "setProfile:", acceptedTypes: ["q", "Q", "i", "I"])
    for name in ["setRate:", "setPitch:", "setVolume:"] {
      try Self.requireSetter(on: resolvedRequestClass, name: name, acceptedTypes: ["d", "f"])
    }

    engineInit = unsafeBitCast(method_getImplementation(initMethod), to: EngineInit.self)
    preheat = unsafeBitCast(method_getImplementation(preheatMethod), to: Preheat.self)
    synthesize = unsafeBitCast(
      method_getImplementation(synthesizeMethod), to: Synthesize.self)
    stopSynthesis = unsafeBitCast(method_getImplementation(stopMethod), to: Stop.self)
    getASBD = unsafeBitCast(method_getImplementation(asbdMethod), to: GetASBD.self)
  }

  func makeEngine(for asset: SiriVoiceAsset) throws -> SiriPrivateTTSEngine {
    guard
      let allocation = engineClass.perform(NSSelectorFromString("alloc")),
      let allocated = allocation.takeUnretainedValue() as? NSObject
    else {
      throw SiriTTSError.privateABIChanged("SiriTTSSynthesisEngine allocation failed")
    }
    var initError: NSObject?

    // UAF stores the engine's own VoiceServices Info.plist inside AssetData.
    // Passing the outer `.asset` directory initializes but fails synthesis
    // with `map::at: key not found`; the inner directory is intentionally
    // supplied for both arguments.
    guard
      let engine = engineInit(
        allocated,
        initSelector,
        asset.voicePath as NSString,
        asset.resourcePath as NSString,
        &initError)
    else {
      let detail = (initError as? NSError)?.localizedDescription ?? "initializer returned nil"
      throw SiriTTSError.engineInitializationFailed(asset.id, detail)
    }
    if let error = initError as? NSError {
      throw SiriTTSError.engineInitializationFailed(asset.id, error.localizedDescription)
    }

    var preheatError: AnyObject?
    guard preheat(engine, preheatSelector, &preheatError) else {
      let detail = (preheatError as? NSError)?.localizedDescription ?? "unknown error"
      throw SiriTTSError.enginePreheatFailed(asset.id, detail)
    }

    let format = getASBD(engine, asbdSelector)
    guard Self.isRequiredPCMFormat(format) else {
      throw SiriTTSError.unsupportedAudioFormat(
        asset.id,
        "rate=\(format.mSampleRate), format=\(format.mFormatID), "
          + "flags=\(format.mFormatFlags), channels=\(format.mChannelsPerFrame), "
          + "bits=\(format.mBitsPerChannel)")
    }

    return SiriPrivateTTSEngine(
      runtime: self,
      engine: engine,
      asset: asset,
      synthesize: synthesize,
      synthesizeSelector: synthesizeSelector,
      stopSynthesis: stopSynthesis,
      stopSelector: stopSelector,
      requestClass: requestClass)
  }

  private static func isRequiredPCMFormat(_ format: AudioStreamBasicDescription) -> Bool {
    let requiredFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    let prohibitedFlags =
      kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian
      | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsAlignedHigh
    return format.mSampleRate == Double(SiriVoiceCatalog.requiredSampleRate)
      && format.mFormatID == kAudioFormatLinearPCM
      && format.mChannelsPerFrame == 1
      && format.mBitsPerChannel == 16
      && format.mBytesPerFrame == 2
      && format.mBytesPerPacket == 2
      && format.mFramesPerPacket == 1
      && (format.mFormatFlags & requiredFlags) == requiredFlags
      && (format.mFormatFlags & prohibitedFlags) == 0
      && format.mReserved == 0
  }

  private static func requireMethod(
    on cls: AnyClass, selector: Selector, encoding expected: String
  ) throws -> Method {
    guard let method = class_getInstanceMethod(cls, selector) else {
      throw SiriTTSError.privateABIChanged("missing selector \(NSStringFromSelector(selector))")
    }
    guard let typeEncoding = method_getTypeEncoding(method) else {
      throw SiriTTSError.privateABIChanged(
        "\(NSStringFromSelector(selector)) has no Objective-C type encoding")
    }
    let actual = String(cString: typeEncoding)
    guard actual == expected else {
      throw SiriTTSError.privateABIChanged(
        "\(NSStringFromSelector(selector)) has encoding \(actual), expected \(expected)")
    }
    return method
  }

  private static func requireSetter(
    on cls: AnyClass, name: String, acceptedTypes: Set<String>
  ) throws {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(cls, selector),
      method_getNumberOfArguments(method) == 3
    else { throw SiriTTSError.privateABIChanged("missing setter \(name)") }
    let returnType = method_copyReturnType(method)
    defer { free(returnType) }
    guard String(cString: returnType) == "v",
      let argumentType = method_copyArgumentType(method, 2)
    else { throw SiriTTSError.privateABIChanged("setter \(name) has an invalid signature") }
    defer { free(argumentType) }
    let actual = String(cString: argumentType)
    guard acceptedTypes.contains(actual) else {
      throw SiriTTSError.privateABIChanged(
        "setter \(name) has value type \(actual), expected \(acceptedTypes.sorted())")
    }
  }
}

/// One loaded private engine. Calls must be serialized by SiriVoiceLane.
final class SiriPrivateTTSEngine: @unchecked Sendable {
  private let runtime: SiriPrivateTTSRuntime
  private let engine: NSObject
  private let asset: SiriVoiceAsset
  private let synthesizeFunction: SiriPrivateTTSRuntime.Synthesize
  private let synthesizeSelector: Selector
  private let stopFunction: SiriPrivateTTSRuntime.Stop
  private let stopSelector: Selector
  private let requestClass: NSObject.Type

  init(
    runtime: SiriPrivateTTSRuntime,
    engine: NSObject,
    asset: SiriVoiceAsset,
    synthesize: @escaping SiriPrivateTTSRuntime.Synthesize,
    synthesizeSelector: Selector,
    stopSynthesis: @escaping SiriPrivateTTSRuntime.Stop,
    stopSelector: Selector,
    requestClass: NSObject.Type
  ) {
    self.runtime = runtime
    self.engine = engine
    self.asset = asset
    synthesizeFunction = synthesize
    self.synthesizeSelector = synthesizeSelector
    stopFunction = stopSynthesis
    self.stopSelector = stopSelector
    self.requestClass = requestClass
  }

  /// Developer probe (SIRI_TIMINGS_PROBE=1): dumps the shape of the private
  /// word-timings payload to stderr, which the worker inherits, so the
  /// element class and time base can be characterized without any IPC
  /// change. Never active in normal operation and never alters synthesis.
  private static let timingsProbeEnabled =
    ProcessInfo.processInfo.environment["SIRI_TIMINGS_PROBE"] == "1"

  private static func probeWordTimingsIfEnabled(_ elements: [NSObject]) {
    guard timingsProbeEnabled else { return }
    FileHandle.standardError.write(
      Data("timings-probe: batch count=\(elements.count)\n".utf8))
    for (index, element) in elements.prefix(6).enumerated() {
      var names: [String] = []
      var propertyCount: UInt32 = 0
      if let properties = class_copyPropertyList(type(of: element), &propertyCount) {
        names = (0..<Int(propertyCount)).map {
          String(cString: property_getName(properties[$0]))
        }
        free(properties)
      }
      let line = "timings-probe: [\(index)] class=\(type(of: element))"
        + " properties=\(names.joined(separator: ","))"
        + " description=\(element.description.prefix(200))"
      FileHandle.standardError.write(Data((line + "\n").utf8))
      // KVC only on declared properties: an undefined key would raise an
      // Objective-C exception that Swift cannot catch.
      for key in names.prefix(24) {
        let value = element.value(forKey: key)
        FileHandle.standardError.write(
          Data("timings-probe:   \(key)=\(String(describing: value).prefix(120))\n".utf8))
      }
    }
  }

  func synthesizePCM(text: String) throws -> Data {
    let maximumPCMBytes = 128 << 20
    let request = requestClass.init()
    let pcmLock = NSLock()
    var pcm = Data()
    var exceededLimit = false
    let audioHandler: SiriAudioHandler = { data in
      pcmLock.lock()
      defer { pcmLock.unlock() }
      guard !exceededLimit else { return }
      let chunk = data as Data
      guard chunk.count <= maximumPCMBytes - pcm.count else {
        exceededLimit = true
        return
      }
      pcm.append(chunk)
    }
    let wordTimingsHandler: SiriWordTimingsHandler = { elements in
      Self.probeWordTimingsIfEnabled(elements)
    }

    request.setValuesForKeys([
      "text": text,
      "privacySensitive": true,
      "requestId": UUID().uuidString,
      "profile": 1,
      "rate": 1.0,
      "pitch": 1.0,
      "volume": 1.0,
    ])
    request.perform(NSSelectorFromString("setAudioHandler:"), with: audioHandler)
    request.perform(
      NSSelectorFromString("setWordTimingsHandler:"), with: wordTimingsHandler)

    // Natural voices advertise this style in their asset metadata. The
    // current ABI requires a dynamicPromptHandler whenever promptStyle is set.
    var dynamicPromptHandler: SiriDynamicPromptHandler?
    if asset.supportsNarration {
      let handler: SiriDynamicPromptHandler = { _ in }
      dynamicPromptHandler = handler
      request.perform(
        NSSelectorFromString("setDynamicPromptHandler:"), with: handler)
      request.setValue("narration", forKey: "promptStyle")
    }

    var synthesisError: NSObject?
    let success = synthesizeFunction(
      engine, synthesizeSelector, request, &synthesisError)
    _ = dynamicPromptHandler  // retain the block until synchronous synthesis returns

    if let error = synthesisError as? NSError {
      throw SiriTTSError.synthesisFailed(asset.id, error.localizedDescription)
    }
    guard success else {
      throw SiriTTSError.synthesisFailed(asset.id, "private engine returned false")
    }
    guard !exceededLimit else {
      throw SiriTTSError.synthesisFailed(asset.id, "audio exceeded the 128 MiB safety limit")
    }
    guard !pcm.isEmpty else {
      throw SiriTTSError.noAudioProduced(asset.id)
    }
    return pcm
  }

  func stop() {
    stopFunction(engine, stopSelector)
  }
}
