import XCTest

@testable import SiriTTSCore

final class SiriTTSRuntimeIdentityTests: XCTestCase {
  func testCurrentIdentityIncludesOSBuildAndFramework() {
    let value = SiriTTSRuntimeIdentity.current()
    XCTAssertFalse(value.macOSVersion.isEmpty)
    XCTAssertFalse(value.macOSBuild.isEmpty)
    XCTAssertEqual(value.frameworkIdentifier, "com.apple.siri.SiriTTSService")
    XCTAssertFalse(value.frameworkVersion.isEmpty)
    XCTAssertTrue(value.modelRevision.contains(value.macOSVersion))
    XCTAssertTrue(value.modelRevision.contains(value.macOSBuild))
  }
}
