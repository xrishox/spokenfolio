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
    return format.mSampleRate == Double(SiriVoiceCatalog.requiredSampleRate)
      && format.mFormatID == kAudioFormatLinearPCM
      && format.mChannelsPerFrame == 1
      && format.mBitsPerChannel == 16
      && format.mBytesPerFrame == 2
      && (format.mFormatFlags & requiredFlags) == requiredFlags
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

  func synthesizePCM(text: String) throws -> Data {
    let request = requestClass.init()
    let pcmLock = NSLock()
    var pcm = Data()
    let audioHandler: SiriAudioHandler = { data in
      pcmLock.lock()
      pcm.append(data as Data)
      pcmLock.unlock()
    }
    let wordTimingsHandler: SiriWordTimingsHandler = { _ in }

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
      dynamicPromptHandler = { _ in }
      request.perform(
        NSSelectorFromString("setDynamicPromptHandler:"), with: dynamicPromptHandler!)
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
    guard !pcm.isEmpty else {
      throw SiriTTSError.noAudioProduced(asset.id)
    }
    return pcm
  }

  func stop() {
    stopFunction(engine, stopSelector)
  }
}
