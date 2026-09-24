import ApplicationServices
import CoreGraphics
import XCTest

@testable import Winnow

final class WindowIdentityBridgeTests: XCTestCase {
  func testReferenceRegistryUsesCFEqualityInsteadOfHashAlone() {
    let firstElement = AXUIElementCreateApplication(42)
    let equivalentElement = AXUIElementCreateApplication(42)
    XCTAssertTrue(CFEqual(firstElement, equivalentElement))

    let first = AXWindowReference(element: firstElement)
    let second = AXWindowReference(element: equivalentElement)
    let other = AXWindowReference(
      element: AXUIElementCreateApplication(43)
    )

    XCTAssertEqual(first.identityToken, second.identityToken)
    XCTAssertNotEqual(first.identityToken, other.identityToken)
  }

  func testBridgeAcceptsOnlyUsableWindowIdentifiers() {
    let element = AXUIElementCreateApplication(42)

    XCTAssertEqual(
      WindowIdentityBridge(lookup: { _ in 91 })
        .windowServerIdentifier(for: element),
      91
    )
    XCTAssertNil(
      WindowIdentityBridge(lookup: { _ in 0 })
        .windowServerIdentifier(for: element)
    )
    XCTAssertNil(
      WindowIdentityBridge(lookup: { _ in CGWindowID.max })
        .windowServerIdentifier(for: element)
    )
  }
}
