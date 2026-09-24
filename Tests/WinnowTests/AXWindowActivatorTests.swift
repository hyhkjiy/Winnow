import ApplicationServices
import Dispatch
import XCTest

@testable import Winnow

final class AXWindowActivatorTests: XCTestCase {
  func testRestoresAndPreciselyActivatesMinimizedWindowInOrder() async throws {
    let queue = DispatchQueue(label: "AXWindowActivatorTests")
    let queueKey = DispatchSpecificKey<Bool>()
    queue.setSpecific(key: queueKey, value: true)

    let client = FakeAXWindowSystemClient()
    client.isOnExpectedQueue = {
      DispatchQueue.getSpecific(key: queueKey) == true
    }
    let discovery = StubWindowDiscovery(result: .success([]))
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery,
      queue: queue
    )

    try await activator.activate(window(isMinimized: true))

    XCTAssertEqual(
      client.events,
      [
        "trust",
        "unhide:42",
        "minimized:false",
        "activate:42",
        "raise",
        "main",
        "focused",
      ]
    )
    XCTAssertEqual(client.unexpectedQueueCalls, 0)
    XCTAssertEqual(discovery.callCount, 0)
  }

  func testInvalidReferenceRediscoveryOccursOnlyOnce() async throws {
    let client = FakeAXWindowSystemClient()
    let staleReference = makeAXReference()
    let refreshedReference = makeAXReference()
    client.invalidRaiseReferences = [ObjectIdentifier(staleReference)]

    let originalWindow = window(reference: staleReference)
    let refreshedWindow = window(reference: refreshedReference)
    let discovery = StubWindowDiscovery(result: .success([refreshedWindow]))
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery
    )

    try await activator.activate(originalWindow)

    XCTAssertEqual(discovery.callCount, 1)
    XCTAssertEqual(
      client.events,
      [
        "trust",
        "unhide:42",
        "activate:42",
        "raise",
        "trust",
        "unhide:42",
        "activate:42",
        "raise",
        "main",
        "focused",
      ]
    )
  }

  func testSecondInvalidReferenceFallsBackWithoutAnotherRediscovery() async throws {
    let client = FakeAXWindowSystemClient()
    let staleReference = makeAXReference()
    let refreshedReference = makeAXReference()
    client.invalidRaiseReferences = [
      ObjectIdentifier(staleReference),
      ObjectIdentifier(refreshedReference),
    ]

    let discovery = StubWindowDiscovery(
      result: .success([window(reference: refreshedReference)])
    )
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery
    )

    try await activator.activate(window(reference: staleReference))

    XCTAssertEqual(discovery.callCount, 1)
    XCTAssertEqual(
      Array(client.events.suffix(3)),
      ["raise", "unhide:42", "activate:42"]
    )
  }

  func testNonInvalidAXFailureAttemptsRemainingBestEffortSteps() async throws {
    let client = FakeAXWindowSystemClient()
    let reference = makeAXReference()
    client.raiseErrors[ObjectIdentifier(reference)] = .cannotComplete
    let discovery = StubWindowDiscovery(result: .success([]))
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery
    )

    try await activator.activate(window(reference: reference))

    XCTAssertEqual(discovery.callCount, 0)
    XCTAssertEqual(
      client.events,
      [
        "trust",
        "unhide:42",
        "activate:42",
        "raise",
        "main",
        "focused",
      ]
    )
  }

  func testPermissionRevocationFallsBackToApplicationActivation() async throws {
    let client = FakeAXWindowSystemClient()
    client.trusted = false
    let discovery = StubWindowDiscovery(result: .success([]))
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery
    )

    try await activator.activate(window())

    XCTAssertEqual(discovery.callCount, 0)
    XCTAssertEqual(
      client.events,
      ["trust", "unhide:42", "activate:42"]
    )
  }

  func testAPIDisabledDuringActivationStopsAXAndFallsBack() async throws {
    let client = FakeAXWindowSystemClient()
    let reference = makeAXReference()
    client.raiseErrors[ObjectIdentifier(reference)] = .apiDisabled
    let discovery = StubWindowDiscovery(result: .success([]))
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery
    )

    try await activator.activate(window(reference: reference))

    XCTAssertEqual(discovery.callCount, 0)
    XCTAssertEqual(
      client.events,
      [
        "trust",
        "unhide:42",
        "activate:42",
        "raise",
        "unhide:42",
        "activate:42",
      ]
    )
  }

  func testAmbiguousSameTitleWindowFallsBackAfterInvalidReference() async throws {
    let client = FakeAXWindowSystemClient()
    let staleReference = makeAXReference()
    client.invalidRaiseReferences = [ObjectIdentifier(staleReference)]

    let refreshedWindow = window(
      reference: makeAXReference(),
      sameTitleWindowCount: 2
    )
    let discovery = StubWindowDiscovery(result: .success([refreshedWindow]))
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery
    )

    try await activator.activate(
      window(
        reference: staleReference,
        sameTitleWindowCount: 2
      )
    )

    XCTAssertEqual(discovery.callCount, 1)
    XCTAssertEqual(
      client.events,
      [
        "trust",
        "unhide:42",
        "activate:42",
        "raise",
        "unhide:42",
        "activate:42",
      ]
    )
  }

  func testInventoryOnlyWindowActivatesApplicationThenRecoversExactReference() async throws {
    let client = FakeAXWindowSystemClient()
    let refreshedWindow = window(
      reference: makeAXReference(),
      windowServerIdentifier: 91
    )
    let discovery = StubWindowDiscovery(result: .success([refreshedWindow]))
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery
    )

    try await activator.activate(
      window(
        reference: nil,
        windowServerIdentifier: 91
      )
    )

    XCTAssertEqual(discovery.callCount, 1)
    XCTAssertEqual(
      client.events,
      [
        "menu:Project Notes",
        "unhide:42",
        "activate:42",
        "trust",
        "unhide:42",
        "activate:42",
        "raise",
        "main",
        "focused",
      ]
    )
  }

  func testInventoryOnlyWindowUsesUniqueWindowMenuItemBeforeRediscovery() async throws {
    let client = FakeAXWindowSystemClient()
    client.menuSelectionResult = true
    let discovery = StubWindowDiscovery(
      result: .success([
        window(
          reference: makeAXReference(),
          windowServerIdentifier: 92
        )
      ])
    )
    let activator = AXWindowActivator(
      systemClient: client,
      windowDiscovery: discovery
    )

    try await activator.activate(
      window(
        reference: nil,
        windowServerIdentifier: 92
      )
    )

    XCTAssertEqual(
      client.events,
      [
        "menu:Project Notes",
        "trust",
        "unhide:42",
        "activate:42",
        "raise",
        "main",
        "focused",
      ]
    )
  }

  private func window(
    reference: AXWindowReference? = makeAXReference(),
    isMinimized: Bool = false,
    sameTitleWindowCount: Int = 1,
    windowServerIdentifier: CGWindowID? = nil
  ) -> WindowItem {
    WindowItem(
      processIdentifier: 42,
      applicationName: "Safari",
      title: "Project Notes",
      windowServerIdentifier: windowServerIdentifier,
      sameTitleWindowCount: sameTitleWindowCount,
      isMinimized: isMinimized,
      accessibilityReference: reference
    )
  }
}
