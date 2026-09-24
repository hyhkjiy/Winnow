import ApplicationServices
import Dispatch
import XCTest

@testable import Winnow

final class AXWindowDiscoveryTests: XCTestCase {
  func testDiscoversEligibleWindowsAndFiltersInvalidTargets() async throws {
    let queue = DispatchQueue(label: "AXWindowDiscoveryTests")
    let queueKey = DispatchSpecificKey<Bool>()
    queue.setSpecific(key: queueKey, value: true)

    let client = FakeAXWindowSystemClient()
    client.isOnExpectedQueue = {
      DispatchQueue.getSpecific(key: queueKey) == true
    }
    client.applications = [
      application(processIdentifier: 99, name: "Winnow"),
      application(processIdentifier: 10, name: "Safari"),
      application(
        processIdentifier: 11,
        name: "Menu Extra",
        isRegularApplication: false
      ),
      application(
        processIdentifier: 12,
        name: "Terminated",
        isTerminated: true
      ),
    ]

    let standardReference = makeAXReference()
    let unknownReference = makeAXReference()
    client.windowsByProcessIdentifier[10] = [
      window(
        reference: standardReference,
        subrole: kAXStandardWindowSubrole as String,
        title: "Project Notes",
        isMinimized: true
      ),
      window(
        subrole: kAXFloatingWindowSubrole as String,
        title: "Find"
      ),
      window(
        role: kAXMenuRole as String,
        title: "File"
      ),
      window(
        reference: unknownReference,
        subrole: kAXUnknownSubrole as String,
        title: "Electron Document"
      ),
      window(
        subrole: kAXStandardWindowSubrole as String,
        title: "   ",
        frame: CGRect(x: 0, y: 0, width: 80, height: 40)
      ),
    ]

    let discovery = AXWindowDiscovery(
      systemClient: client,
      queue: queue,
      ownProcessIdentifier: 99
    )

    let windows = try await discovery.discoverWindows()

    XCTAssertEqual(windows.count, 2)
    XCTAssertEqual(windows.map(\.title), ["Electron Document", "Project Notes"])
    XCTAssertEqual(windows.map(\.applicationName), ["Safari", "Safari"])
    XCTAssertEqual(windows.map(\.isMinimized), [false, true])
    XCTAssertTrue(windows[0].accessibilityReference === unknownReference)
    XCTAssertTrue(windows[1].accessibilityReference === standardReference)
    XCTAssertEqual(client.unexpectedQueueCalls, 1)
    XCTAssertFalse(client.events.contains("windows:99"))
    XCTAssertFalse(client.events.contains("windows:11"))
    XCTAssertFalse(client.events.contains("windows:12"))
  }

  func testDoesNotEnumerateWhenAccessibilityPermissionIsMissing() async {
    let client = FakeAXWindowSystemClient()
    client.trusted = false
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    let discovery = AXWindowDiscovery(systemClient: client)

    do {
      _ = try await discovery.discoverWindows()
      XCTFail("Expected accessibility permission error")
    } catch WindowServiceError.accessibilityPermissionRequired {
      XCTAssertEqual(client.events, ["trust"])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testGlobalTrustFailureIsPermissionRevocation() async {
    let client = FakeAXWindowSystemClient()
    client.trusted = false
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    let discovery = AXWindowDiscovery(systemClient: client)

    do {
      _ = try await discovery.discoverWindows()
      XCTFail("Expected accessibility permission error")
    } catch WindowServiceError.accessibilityPermissionRequired {
      XCTAssertEqual(client.events, ["trust"])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSinglePIDAPIDisabledDoesNotMaskHealthyProcess() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [
      application(processIdentifier: 10, name: "Old Winnow"),
      application(processIdentifier: 20, name: "Safari"),
    ]
    client.windowErrors[10] = .accessibility(.apiDisabled)
    client.windowsByProcessIdentifier[20] = [window(title: "Healthy")]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      ownBundleIdentifier: "app.winnow.Winnow"
    )

    let windows = try await discovery.refreshWindowsUsingAccessibilityOnly()

    XCTAssertEqual(windows.map(\.title), ["Healthy"])
    XCTAssertTrue(client.trusted)
  }

  func testPresentationReportCountsUnavailableProcessWithoutSharedState() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [
      application(processIdentifier: 10, name: "Unresponsive"),
      application(processIdentifier: 20, name: "Safari"),
    ]
    client.windowErrors[10] = .accessibility(.cannotComplete)
    client.windowsByProcessIdentifier[20] = [window(title: "Healthy")]
    let discovery = AXWindowDiscovery(systemClient: client)

    let report = try await discovery.discoverReportForPresentation()

    XCTAssertEqual(report.windows.map(\.title), ["Healthy"])
    XCTAssertEqual(report.unavailableApplicationCount, 1)
  }

  func testRealWindowIdentifierIsExactAndStableAcrossScans() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    let reference = makeAXReference()
    let frame = CGRect(x: 100, y: 80, width: 900, height: 700)
    client.windowsByProcessIdentifier[10] = [
      window(
        reference: reference,
        windowServerIdentifier: 77,
        title: "Project Notes",
        frame: frame
      )
    ]
    let inventoryClient = FakeWindowInventoryClient()
    inventoryClient.windowsResult = [
      inventoryWindow(
        identifier: 77,
        processIdentifier: 10,
        applicationName: "Safari",
        title: "Project Notes",
        frame: frame
      )
    ]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      inventoryClient: inventoryClient
    )

    let firstResult = try await discovery.discoverWindows()
    XCTAssertEqual(firstResult.count, 1)
    XCTAssertEqual(firstResult[0].windowServerIdentifier, 77)
    XCTAssertEqual(firstResult[0].discoveryConfidence, .exact)
    XCTAssertTrue(firstResult[0].accessibilityReference === reference)

    let secondResult = try await discovery.discoverWindowsForPresentation()

    XCTAssertEqual(secondResult.count, 1)
    XCTAssertEqual(secondResult[0].id, firstResult[0].id)
    XCTAssertEqual(secondResult[0].discoveryConfidence, .exact)
    XCTAssertTrue(secondResult[0].accessibilityReference === reference)
    XCTAssertEqual(inventoryClient.callCount, 1)
    XCTAssertEqual(inventoryClient.immediateCallCount, 1)
  }

  func testIncludesInventoryOnlyWindowFromAnotherSpace() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    let inventoryClient = FakeWindowInventoryClient()
    inventoryClient.windowsResult = [
      inventoryWindow(
        identifier: 88,
        processIdentifier: 10,
        applicationName: "Safari",
        title: "Other Space",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600)
      )
    ]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      inventoryClient: inventoryClient
    )

    let windows = try await discovery.discoverWindows()

    XCTAssertEqual(windows.count, 1)
    XCTAssertEqual(windows[0].title, "Other Space")
    XCTAssertEqual(windows[0].windowServerIdentifier, 88)
    XCTAssertEqual(windows[0].discoveryConfidence, .inventoryOnly)
    XCTAssertNil(windows[0].accessibilityReference)
  }

  func testAccessibilityOnlyRefreshDoesNotRequestScreenCaptureInventory() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowsByProcessIdentifier[10] = [
      window(title: "Project Notes")
    ]
    let inventoryClient = FakeWindowInventoryClient()
    let discovery = AXWindowDiscovery(
      systemClient: client,
      inventoryClient: inventoryClient
    )

    let windows = try await discovery.refreshWindowsUsingAccessibilityOnly()

    XCTAssertEqual(windows.map(\.title), ["Project Notes"])
    XCTAssertEqual(inventoryClient.callCount, 0)
  }

  func testPresentationDiscoveryOnlyReturnsAccessibilityConfirmedWindows() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    let reference = makeAXReference()
    client.windowsByProcessIdentifier[10] = [
      window(
        reference: reference,
        title: "Project Notes",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600)
      )
    ]
    let inventoryClient = FakeWindowInventoryClient()
    inventoryClient.windowsResult = [
      inventoryWindow(
        identifier: 91,
        processIdentifier: 10,
        applicationName: "Safari",
        title: "Project Notes",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600)
      ),
      inventoryWindow(
        identifier: 92,
        processIdentifier: 10,
        applicationName: "Safari",
        title: "Capture Surface",
        frame: CGRect(x: 0, y: 0, width: 400, height: 300)
      ),
    ]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      inventoryClient: inventoryClient
    )

    let windows = try await discovery.discoverWindowsForPresentation()

    XCTAssertEqual(windows.map(\.title), ["Project Notes"])
    XCTAssertEqual(windows.map(\.discoveryConfidence), [.probable])
    XCTAssertNil(windows[0].windowServerIdentifier)
    XCTAssertTrue(windows[0].accessibilityReference === reference)
    XCTAssertEqual(inventoryClient.callCount, 0)
    XCTAssertEqual(inventoryClient.immediateCallCount, 1)
    XCTAssertEqual(client.events, ["trust", "applications", "windows:10", "trust"])
  }

  func testPresentationDiscoveryRejectsInventoryOnlyWindows() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    let inventoryClient = FakeWindowInventoryClient()
    inventoryClient.windowsResult = [
      inventoryWindow(
        identifier: 91,
        processIdentifier: 10,
        applicationName: "Safari",
        title: "Capture Surface",
        frame: CGRect(x: 0, y: 0, width: 400, height: 300)
      )
    ]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      inventoryClient: inventoryClient
    )

    let windows = try await discovery.discoverWindowsForPresentation()

    XCTAssertTrue(windows.isEmpty)
  }

  func testUsesApplicationNameForUntitledAccessibilityWindow() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowsByProcessIdentifier[10] = [
      window(title: "   ")
    ]
    let discovery = AXWindowDiscovery(systemClient: client)

    let windows = try await discovery.discoverWindowsForPresentation()

    XCTAssertEqual(windows.map(\.title), ["Safari"])
  }

  func testAXOnlyIdentityRemainsStableAcrossScans() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    let reference = makeAXReference()
    client.windowsByProcessIdentifier[10] = [
      window(reference: reference, title: "Project Notes")
    ]
    let discovery = AXWindowDiscovery(systemClient: client)

    let first = try await discovery.refreshWindowsUsingAccessibilityOnly()
    let second = try await discovery.refreshWindowsUsingAccessibilityOnly()

    XCTAssertEqual(first[0].id, second[0].id)
    XCTAssertEqual(first[0].identity, second[0].identity)
    XCTAssertEqual(second[0].discoveryConfidence, .probable)
  }

  func testTimedOutPIDReturnsStaleCacheAndDoesNotStartDuplicateScan() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowsByProcessIdentifier[10] = [window(title: "Healthy")]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      perProcessBudget: 0.02,
      batchBudget: 0.04,
      staleRetention: 1,
      maximumConcurrentProcessScans: 1
    )
    _ = try await discovery.refreshWindowsUsingAccessibilityOnly()

    client.windowDelays[10] = 0.2
    client.windowsByProcessIdentifier[10] = [window(title: "Late")]
    let timedOut = try await discovery.refreshWindowsUsingAccessibilityOnly()
    let whileInFlight = try await discovery.refreshWindowsUsingAccessibilityOnly()

    XCTAssertEqual(timedOut.map(\.title), ["Healthy"])
    XCTAssertEqual(timedOut.map(\.discoveryFreshness), [.stale(.timedOut)])
    XCTAssertEqual(
      whileInFlight.map(\.discoveryFreshness),
      [.stale(.scanAlreadyInFlight)]
    )
    XCTAssertEqual(client.windowCallCount(for: 10), 2)
  }

  func testLateTimedOutResultDoesNotReplaceHealthyCache() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowsByProcessIdentifier[10] = [window(title: "Healthy")]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      perProcessBudget: 0.02,
      batchBudget: 0.04,
      staleRetention: 1,
      maximumConcurrentProcessScans: 1
    )
    _ = try await discovery.refreshWindowsUsingAccessibilityOnly()

    client.windowDelays[10] = 0.1
    client.windowsByProcessIdentifier[10] = [window(title: "Late")]
    _ = try await discovery.refreshWindowsUsingAccessibilityOnly()
    try await Task.sleep(nanoseconds: 180_000_000)

    client.windowDelays[10] = 0
    client.windowErrors[10] = .accessibility(.cannotComplete)
    let afterLateCompletion = try await discovery.refreshWindowsUsingAccessibilityOnly()

    XCTAssertEqual(afterLateCompletion.map(\.title), ["Healthy"])
    XCTAssertEqual(
      afterLateCompletion.map(\.discoveryFreshness),
      [.stale(.failed)]
    )
  }

  func testQueuedScanExpiredBeforeStartDoesNotCallAX() async {
    let client = FakeAXWindowSystemClient()
    client.applications = [
      application(processIdentifier: 10, name: "Slow"),
      application(processIdentifier: 20, name: "Queued"),
    ]
    client.windowDelays[10] = 0.15
    client.windowsByProcessIdentifier[10] = [window(title: "Slow")]
    client.windowsByProcessIdentifier[20] = [window(title: "Must Not Run")]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      perProcessBudget: 0.02,
      batchBudget: 0.04,
      maximumConcurrentProcessScans: 1
    )

    do {
      _ = try await discovery.refreshWindowsUsingAccessibilityOnly()
      XCTFail("Expected unavailable discovery")
    } catch WindowServiceError.windowDiscoveryUnavailable {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    try? await Task.sleep(nanoseconds: 220_000_000)

    XCTAssertEqual(client.windowCallCount(for: 10), 1)
    XCTAssertEqual(client.windowCallCount(for: 20), 0)
  }

  func testStaleExactWindowDoesNotDuplicateInventoryOnlyWindow() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowsByProcessIdentifier[10] = [
      window(windowServerIdentifier: 77, title: "Project Notes")
    ]
    let inventory = FakeWindowInventoryClient()
    inventory.windowsResult = [
      inventoryWindow(
        identifier: 77,
        processIdentifier: 10,
        applicationName: "Safari",
        title: "Project Notes",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600)
      )
    ]
    let discovery = AXWindowDiscovery(
      systemClient: client,
      inventoryClient: inventory
    )
    _ = try await discovery.discoverWindows()

    client.windowErrors[10] = .accessibility(.cannotComplete)
    let stale = try await discovery.discoverWindows()

    XCTAssertEqual(stale.count, 1)
    XCTAssertEqual(stale[0].windowServerIdentifier, 77)
    XCTAssertEqual(stale[0].discoveryFreshness, .stale(.failed))
  }

  func testDuplicateRealWindowIdentifierIsReturnedOnce() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowsByProcessIdentifier[10] = [
      window(windowServerIdentifier: 77, title: "First"),
      window(windowServerIdentifier: 77, title: "Duplicate"),
    ]
    let discovery = AXWindowDiscovery(systemClient: client)

    let windows = try await discovery.refreshWindowsUsingAccessibilityOnly()

    XCTAssertEqual(windows.count, 1)
    XCTAssertEqual(windows[0].windowServerIdentifier, 77)
  }

  func testLiveClientDoesNotSwallowApplicationWindowsFailure() {
    let client = LiveAXWindowSystemClient(
      copyAttributeValue: { _, attribute, _ in
        if attribute as String == kAXWindowsAttribute as String {
          return .cannotComplete
        }
        return .noValue
      }
    )

    XCTAssertThrowsError(try client.windows(for: 42)) { error in
      XCTAssertEqual(
        error as? AXWindowSystemError,
        .accessibility(.cannotComplete)
      )
    }
  }

  func testLiveClientStopsWhenProcessDeadlineHasExpired() {
    let client = LiveAXWindowSystemClient(processScanBudget: 0)

    XCTAssertThrowsError(try client.windows(for: 42)) { error in
      XCTAssertEqual(error as? AXWindowSystemError, .deadlineExceeded)
    }
  }

  func testAllFailedWithoutCacheThrowsDiscoveryUnavailable() async {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowErrors[10] = .accessibility(.cannotComplete)
    let discovery = AXWindowDiscovery(systemClient: client)

    do {
      _ = try await discovery.refreshWindowsUsingAccessibilityOnly()
      XCTFail("Expected unavailable discovery")
    } catch WindowServiceError.windowDiscoveryUnavailable {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRejectsUnknownWindowWithoutWindowCapabilities() async throws {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowsByProcessIdentifier[10] = [
      window(
        subrole: kAXUnknownSubrole as String,
        title: "Transient Surface",
        supportsRaiseAction: false,
        hasWindowControls: false
      )
    ]
    let discovery = AXWindowDiscovery(systemClient: client)

    let windows = try await discovery.discoverWindowsForPresentation()

    XCTAssertTrue(windows.isEmpty)
  }

  private func application(
    processIdentifier: pid_t,
    name: String,
    bundleURL: URL? = nil,
    isRegularApplication: Bool = true,
    isAccessoryApplication: Bool = false,
    isTerminated: Bool = false
  ) -> RunningApplicationSnapshot {
    RunningApplicationSnapshot(
      processIdentifier: processIdentifier,
      bundleIdentifier: "test.\(name)",
      bundleURL: bundleURL ?? URL(fileURLWithPath: "/Applications/\(name).app"),
      localizedName: name,
      isRegularApplication: isRegularApplication,
      isAccessoryApplication: isAccessoryApplication,
      isTerminated: isTerminated
    )
  }

  private func window(
    reference: AXWindowReference = makeAXReference(),
    windowServerIdentifier: CGWindowID? = nil,
    role: String = kAXWindowRole as String,
    subrole: String? = kAXStandardWindowSubrole as String,
    title: String,
    accessibilityIdentifier: String? = nil,
    supportsRaiseAction: Bool = true,
    hasWindowControls: Bool = true,
    isMinimized: Bool = false,
    frame: CGRect? = nil
  ) -> AXWindowSnapshot {
    AXWindowSnapshot(
      reference: reference,
      windowServerIdentifier: windowServerIdentifier,
      role: role,
      subrole: subrole,
      title: title,
      accessibilityIdentifier: accessibilityIdentifier,
      supportsRaiseAction: supportsRaiseAction,
      hasWindowControls: hasWindowControls,
      isMinimized: isMinimized,
      frame: frame
    )
  }

  private func inventoryWindow(
    identifier: CGWindowID,
    processIdentifier: pid_t,
    applicationName: String,
    title: String,
    frame: CGRect
  ) -> WindowInventorySnapshot {
    WindowInventorySnapshot(
      windowIdentifier: identifier,
      processIdentifier: processIdentifier,
      applicationBundleIdentifier: "test.\(applicationName)",
      applicationName: applicationName,
      title: title,
      frame: frame,
      layer: 0,
      isOnScreen: false,
      isActive: false
    )
  }
}
