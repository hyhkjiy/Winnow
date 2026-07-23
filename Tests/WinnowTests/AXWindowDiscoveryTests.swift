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
        title: "   "
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
    XCTAssertEqual(client.unexpectedQueueCalls, 0)
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

  func testTreatsAPIDisabledDuringEnumerationAsPermissionRevocation() async {
    let client = FakeAXWindowSystemClient()
    client.applications = [application(processIdentifier: 10, name: "Safari")]
    client.windowErrors[10] = .accessibility(.apiDisabled)
    let discovery = AXWindowDiscovery(systemClient: client)

    do {
      _ = try await discovery.discoverWindows()
      XCTFail("Expected accessibility permission error")
    } catch WindowServiceError.accessibilityPermissionRequired {
      XCTAssertEqual(
        client.events,
        ["trust", "applications", "windows:10"]
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func application(
    processIdentifier: pid_t,
    name: String,
    isRegularApplication: Bool = true,
    isTerminated: Bool = false
  ) -> RunningApplicationSnapshot {
    RunningApplicationSnapshot(
      processIdentifier: processIdentifier,
      bundleIdentifier: "test.\(name)",
      localizedName: name,
      isRegularApplication: isRegularApplication,
      isTerminated: isTerminated
    )
  }

  private func window(
    reference: AXWindowReference = makeAXReference(),
    role: String = kAXWindowRole as String,
    subrole: String? = kAXStandardWindowSubrole as String,
    title: String,
    accessibilityIdentifier: String? = nil,
    isMinimized: Bool = false
  ) -> AXWindowSnapshot {
    AXWindowSnapshot(
      reference: reference,
      role: role,
      subrole: subrole,
      title: title,
      accessibilityIdentifier: accessibilityIdentifier,
      isMinimized: isMinimized
    )
  }
}
