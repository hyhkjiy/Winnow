import XCTest

@testable import Winnow

final class WindowInventoryClientTests: XCTestCase {
  func testDeniedPreflightStillAttemptsShareableContentThenPausesAfterTimeout() async throws {
    let requestCount = LockedCounter()
    let client = LiveWindowInventoryClient(
      isScreenCaptureGranted: { false },
      shareableContentTimeout: 0.02,
      shareableContentRetryInterval: 60,
      requestShareableContent: { _ in
        requestCount.increment()
      }
    )

    _ = try await client.windows()
    _ = try await client.windows()

    XCTAssertEqual(requestCount.value, 1)
  }

  func testNewScreenCaptureGrantClearsFailureCooldown() async throws {
    let permission = LockedBoolean(false)
    let requestCount = LockedCounter()
    let client = LiveWindowInventoryClient(
      isScreenCaptureGranted: { permission.value },
      shareableContentTimeout: 1,
      shareableContentRetryInterval: 60,
      requestShareableContent: { completion in
        requestCount.increment()
        completion(
          nil,
          NSError(domain: "WindowInventoryClientTests", code: 1)
        )
      }
    )

    _ = try await client.windows()
    permission.value = true
    _ = try await client.windows()

    XCTAssertEqual(requestCount.value, 2)
  }

  func testFallbackKeepsEveryVisibleWindowForRegularApplications() {
    let candidates = [
      window(
        identifier: 1,
        processIdentifier: 10,
        applicationName: "Safari",
        frame: CGRect(x: 0, y: 0, width: 900, height: 700)
      ),
      window(
        identifier: 2,
        processIdentifier: 10,
        applicationName: "Safari",
        frame: CGRect(x: 0, y: 0, width: 300, height: 200)
      ),
      window(
        identifier: 3,
        processIdentifier: 20,
        applicationName: "Code",
        frame: CGRect(x: 0, y: 0, width: 900, height: 700),
        isOnScreen: false
      ),
      window(
        identifier: 4,
        processIdentifier: 30,
        applicationName: "AutoFill",
        frame: CGRect(x: 0, y: 0, width: 900, height: 700)
      ),
    ]

    let windows = LiveWindowInventoryClient.filteredFallbackWindows(
      candidates,
      regularApplicationProcessIdentifiers: [10, 20]
    )

    XCTAssertEqual(windows.map(\.windowIdentifier), [1, 2])
    XCTAssertEqual(windows.map(\.applicationName), ["Safari", "Safari"])
  }

  private func window(
    identifier: CGWindowID,
    processIdentifier: pid_t,
    applicationName: String,
    title: String? = nil,
    frame: CGRect,
    isOnScreen: Bool = true
  ) -> WindowInventorySnapshot {
    WindowInventorySnapshot(
      windowIdentifier: identifier,
      processIdentifier: processIdentifier,
      applicationBundleIdentifier: nil,
      applicationName: applicationName,
      title: title,
      frame: frame,
      layer: 0,
      isOnScreen: isOnScreen,
      isActive: false
    )
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

private final class LockedBoolean: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Bool

  init(_ value: Bool) {
    storedValue = value
  }

  var value: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedValue
    }
    set {
      lock.lock()
      storedValue = newValue
      lock.unlock()
    }
  }
}
