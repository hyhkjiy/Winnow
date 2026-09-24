import AppKit
import XCTest

@testable import Winnow

final class OverlayCoordinatorTests: XCTestCase {
  @MainActor
  func testHiddenRefreshWarmsCacheWithoutOpeningPanels() async {
    let fetched = expectation(description: "discovery")
    let item = WindowItem(processIdentifier: 10, applicationName: "Test", title: "Document")
    let coordinator = OverlayCoordinator(
      session: SearchSession(),
      onDiscoverWindows: {
        fetched.fulfill()
        return WindowDiscoveryReport(windows: [item], unavailableApplicationCount: 0)
      },
      onActivateWindow: { _ in }, onRequestAccessibility: {}
    )
    coordinator.refreshWindows()
    await fulfillment(of: [fetched], timeout: 1)
    // Completion publishes the cache in the same main-actor task as discovery.
    await Task.yield()
    XCTAssertEqual(coordinator.cachedWindows, [item])
    XCTAssertFalse(coordinator.isVisible)
  }

  @MainActor
  func testRefreshBurstDoesNotRunConcurrentScans() async {
    let first = expectation(description: "first scan")
    let second = expectation(description: "one trailing scan")
    var completion: CheckedContinuation<WindowDiscoveryReport, Error>?
    var calls = 0
    let coordinator = OverlayCoordinator(
      session: SearchSession(),
      onDiscoverWindows: {
        calls += 1
        if calls == 1 {
          return try await withCheckedThrowingContinuation {
            completion = $0
            first.fulfill()
          }
        }
        second.fulfill()
        return WindowDiscoveryReport(windows: [], unavailableApplicationCount: 0)
      },
      onActivateWindow: { _ in }, onRequestAccessibility: {},
      hiddenRefreshMinimumInterval: 0.01
    )
    coordinator.refreshWindows()
    await fulfillment(of: [first], timeout: 1)
    for _ in 0..<20 { coordinator.refreshWindows() }
    XCTAssertEqual(calls, 1)
    completion?.resume(
      returning: WindowDiscoveryReport(windows: [], unavailableApplicationCount: 0))
    await fulfillment(of: [second], timeout: 2)
    XCTAssertEqual(calls, 2)
  }

  @MainActor
  func testContinuousHiddenEventsRespectMinimumRefreshInterval() async {
    let first = expectation(description: "first scan")
    var calls = 0
    let coordinator = OverlayCoordinator(
      session: SearchSession(),
      onDiscoverWindows: {
        calls += 1
        if calls == 1 {
          first.fulfill()
        }
        return WindowDiscoveryReport(windows: [], unavailableApplicationCount: 0)
      },
      onActivateWindow: { _ in }, onRequestAccessibility: {}
    )

    coordinator.requestRefresh()
    await fulfillment(of: [first], timeout: 1)

    for _ in 0..<20 {
      coordinator.requestRefresh()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(calls, 1)
    XCTAssertFalse(coordinator.isVisible)
  }

  func testPanelFrameIsFullSizedAndTopCentered() async {
    let frame = await MainActor.run {
      OverlayCoordinator.panelFrame(
        in: NSRect(x: 1440, y: 120, width: 1920, height: 1080)
      )
    }

    XCTAssertEqual(frame.size, NSSize(width: 640, height: 500))
    XCTAssertEqual(frame.midX, 2400)
    XCTAssertEqual(frame.maxY, 1128)
  }

  func testPanelFrameUsesPreferredHeightWithoutMovingTopOrCenter() async {
    let visibleFrame = NSRect(x: 1440, y: 120, width: 1920, height: 1080)
    let defaultFrame = await MainActor.run {
      OverlayCoordinator.panelFrame(in: visibleFrame)
    }
    let resizedFrame = await MainActor.run {
      OverlayCoordinator.panelFrame(in: visibleFrame, preferredHeight: 320)
    }

    XCTAssertEqual(resizedFrame.size, NSSize(width: 640, height: 320))
    XCTAssertEqual(resizedFrame.midX, defaultFrame.midX)
    XCTAssertEqual(resizedFrame.maxY, defaultFrame.maxY)
  }

  func testPanelFrameClampsPreferredHeightToAvailableBounds() async {
    let visibleFrame = NSRect(x: 0, y: 25, width: 640, height: 480)
    let minimumFrame = await MainActor.run {
      OverlayCoordinator.panelFrame(in: visibleFrame, preferredHeight: 100)
    }
    let maximumFrame = await MainActor.run {
      OverlayCoordinator.panelFrame(in: visibleFrame, preferredHeight: 800)
    }

    XCTAssertEqual(minimumFrame.height, 180)
    XCTAssertEqual(maximumFrame.height, 360)
    XCTAssertEqual(minimumFrame.maxY, 433)
    XCTAssertEqual(maximumFrame.maxY, 433)
  }

  func testPanelFrameRespectsSmallVisibleFrameMargins() async {
    let frame = await MainActor.run {
      OverlayCoordinator.panelFrame(
        in: NSRect(x: 0, y: 25, width: 640, height: 480)
      )
    }

    XCTAssertEqual(frame.size, NSSize(width: 560, height: 360))
    XCTAssertEqual(frame.minX, 40)
    XCTAssertEqual(frame.maxY, 433)
  }
}
