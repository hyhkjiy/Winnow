import Combine
import XCTest

@testable import Winnow

final class SearchSessionTests: XCTestCase {
  func testUnavailableAppsDoNotMasqueradeAsAnEmptySuccessfulScan() async {
    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [], unavailableApplicationCount: 1)
      XCTAssertEqual(session.contentState, .failed)
      XCTAssertEqual(session.unavailableApplicationCount, 1)
      session.replaceWindows(with: [])
      XCTAssertEqual(session.contentState, .emptyWindows)
      XCTAssertEqual(session.unavailableApplicationCount, 0)
    }
  }

  func testFiveHundredWindowsReuseTransliterationCacheAcrossContinuousQueries() async {
    let windows = (0..<500).map { index in
      WindowItem(
        processIdentifier: pid_t(index + 1),
        applicationName: "应用\(index)",
        title: "窗口\(index)"
      )
    }

    await MainActor.run {
      let session = SearchSession(transliterationCacheCapacity: 1_024)
      session.replaceWindows(with: windows)
      session.updateQuery("__missing_0__")
      let warmedComputationCount = session.transliterationCache.computationCount

      XCTAssertEqual(warmedComputationCount, 1_000)
      for index in 1...20 {
        session.updateQuery("__missing_\(index)__")
      }

      XCTAssertEqual(
        session.transliterationCache.computationCount,
        warmedComputationCount
      )
      XCTAssertEqual(session.transliterationCache.count, 1_000)
    }
  }

  func testRenamedTitleDoesNotMatchCachedOldTransliteration() async {
    let original = WindowItem(
      processIdentifier: 10,
      applicationName: "Editor",
      title: "旧文档"
    )
    let renamed = WindowItem(
      id: original.id,
      processIdentifier: original.processIdentifier,
      applicationName: original.applicationName,
      title: "新文档"
    )

    await MainActor.run {
      let session = SearchSession(transliterationCacheCapacity: 16)
      session.replaceWindows(with: [original])
      session.updateQuery("jiu")
      XCTAssertEqual(session.visibleWindows, [original])

      session.replaceWindows(with: [renamed])

      XCTAssertTrue(session.visibleWindows.isEmpty)
      XCTAssertEqual(session.contentState, .noMatches)
    }
  }

  func testTransliterationCacheStaysWithinCapacity() {
    let cache = WindowSearchTransliterationCache(capacity: 8)

    for index in 0..<100 {
      _ = cache.transliteration(for: "窗口\(index)")
    }

    XCTAssertEqual(cache.count, 8)
  }

  func testBackgroundRefreshPreservesQuerySelectionAndResults() async {
    let item = window(
      processIdentifier: 10, bundleIdentifier: "test.app",
      applicationName: "Test", title: "Document"
    )
    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [item])
      session.updateQuery("Document")
      session.beginLoading(preservingResults: true)
      XCTAssertEqual(session.contentState, .results)
      XCTAssertEqual(session.query, "Document")
      XCTAssertEqual(session.selectedWindowID, item.id)
      XCTAssertEqual(session.allWindows, [item])
    }
  }

  func testLoadingAndEmptyWindowStatesAreDistinct() async {
    await MainActor.run {
      let session = SearchSession()

      session.beginLoading()
      XCTAssertEqual(session.contentState, .loading)

      session.replaceWindows(with: [])
      XCTAssertEqual(session.contentState, .emptyWindows)
    }
  }

  func testPermissionAndFailureStatesAreDistinct() async {
    await MainActor.run {
      let session = SearchSession()

      session.requireAccessibilityPermission()
      XCTAssertEqual(
        session.contentState,
        .accessibilityPermissionRequired
      )

      session.failDiscovery()
      XCTAssertEqual(session.contentState, .failed)
    }
  }

  func testBuildsAdaptiveEntriesAndSelectsFirstVisibleWindow() async {
    let singleWindow = window(
      processIdentifier: 10,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      title: "Project Notes"
    )
    let firstGroupedWindow = window(
      processIdentifier: 20,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Alpha"
    )
    let secondGroupedWindow = window(
      processIdentifier: 20,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Beta"
    )
    await MainActor.run {
      let session = SearchSession()

      session.replaceWindows(
        with: [singleWindow, secondGroupedWindow, firstGroupedWindow]
      )

      XCTAssertEqual(session.contentState, .results)
      XCTAssertEqual(session.entries.count, 2)
      XCTAssertTrue(session.entries[0].isApplication)
      XCTAssertEqual(session.entries[0].displayTitle, "Code (2)")
      XCTAssertEqual(
        session.entries[0].children.compactMap(\.window),
        [firstGroupedWindow, secondGroupedWindow]
      )
      XCTAssertFalse(session.entries[1].isApplication)
      XCTAssertEqual(
        session.entries[1].displayTitle,
        "Safari — Project Notes"
      )
      XCTAssertEqual(session.selectedNodeID, session.entries[0].id)
      XCTAssertEqual(session.selectedWindow, firstGroupedWindow)
    }
  }

  func testQueryRebuildsEntriesAndKeepsSelectionValid() async {
    let safari = window(
      processIdentifier: 10,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      title: "Project Notes"
    )
    let code = window(
      processIdentifier: 20,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Winnow.swift"
    )
    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [safari, code])
      session.selectWindow(id: safari.id)

      session.updateQuery("winnow")

      XCTAssertEqual(session.visibleWindows, [code])
      XCTAssertEqual(session.selectedWindow, code)
      XCTAssertEqual(session.contentState, .results)

      session.updateQuery("missing")

      XCTAssertTrue(session.visibleWindows.isEmpty)
      XCTAssertNil(session.selectedWindow)
      XCTAssertEqual(session.contentState, .noMatches)
    }
  }

  func testMovesSelectionThroughVisibleWindowsWithWraparound() async {
    let first = window(
      processIdentifier: 10,
      bundleIdentifier: "com.example.First",
      applicationName: "First",
      title: "First"
    )
    let second = window(
      processIdentifier: 20,
      bundleIdentifier: "com.example.Second",
      applicationName: "Second",
      title: "Second"
    )
    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [first, second])

      XCTAssertEqual(session.selectedWindow, first)

      session.moveSelection(by: 1)
      XCTAssertEqual(session.selectedWindow, second)

      session.moveSelection(by: 1)
      XCTAssertEqual(session.selectedWindow, first)

      session.moveSelection(by: -1)
      XCTAssertEqual(session.selectedWindow, second)
    }
  }

  func testMovesSelectionAcrossApplicationsAndWindows() async {
    let first = window(
      processIdentifier: 10,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Alpha"
    )
    let second = window(
      processIdentifier: 10,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Beta"
    )
    let safari = window(
      processIdentifier: 20,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      title: "Notes"
    )

    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [first, second, safari])

      XCTAssertTrue(session.selectedNode?.isApplication == true)
      XCTAssertEqual(session.selectedWindow, first)

      session.moveSelection(by: 1)
      XCTAssertEqual(session.selectedNode?.window, first)

      session.moveSelection(by: 1)
      XCTAssertEqual(session.selectedNode?.window, second)

      session.moveSelection(by: 1)
      XCTAssertEqual(session.selectedNode?.window, safari)
    }
  }

  func testCollapseHidesChildrenAndSelectsApplication() async {
    let first = window(
      processIdentifier: 10,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Alpha"
    )
    let second = window(
      processIdentifier: 10,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Beta"
    )

    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [first, second])
      let application = try! XCTUnwrap(session.entries.first)
      session.selectWindow(id: first.id)

      session.setApplicationExpanded(
        nodeID: application.id,
        expanded: false
      )

      XCTAssertEqual(session.visibleNodes.map(\.id), [application.id])
      XCTAssertEqual(session.selectedNodeID, application.id)
      XCTAssertEqual(session.selectedWindow, first)

      session.setApplicationExpanded(
        nodeID: application.id,
        expanded: true
      )
      XCTAssertEqual(session.visibleNodes.count, 3)
    }
  }

  func testUnchangedExpansionDoesNotPublishSessionChange() async {
    let first = window(
      processIdentifier: 10,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Alpha"
    )
    let second = window(
      processIdentifier: 10,
      bundleIdentifier: "com.example.Code",
      applicationName: "Code",
      title: "Beta"
    )

    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [first, second])
      let application = try! XCTUnwrap(session.entries.first)
      var changeCount = 0
      let cancellable = session.objectWillChange.sink {
        changeCount += 1
      }

      session.setApplicationExpanded(
        nodeID: application.id,
        expanded: true
      )
      XCTAssertEqual(changeCount, 0)

      session.setApplicationExpanded(
        nodeID: application.id,
        expanded: false
      )
      XCTAssertEqual(changeCount, 1)

      session.setApplicationExpanded(
        nodeID: application.id,
        expanded: false
      )
      XCTAssertEqual(changeCount, 1)
      withExtendedLifetime(cancellable) {}
    }
  }

  func testResetClearsSharedSearchState() async {
    let projectWindow = window(
      processIdentifier: 10,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      title: "Project Notes"
    )

    await MainActor.run {
      let session = SearchSession()
      session.beginLoading()
      session.replaceWindows(with: [projectWindow])
      session.updateQuery("project")

      session.reset()

      XCTAssertEqual(session.query, "")
      XCTAssertEqual(session.phase, .idle)
      XCTAssertEqual(session.contentState, .idle)
      XCTAssertTrue(session.allWindows.isEmpty)
      XCTAssertTrue(session.entries.isEmpty)
      XCTAssertNil(session.selectedWindowID)
      XCTAssertNil(session.selectedNodeID)
      XCTAssertTrue(session.collapsedApplicationIDs.isEmpty)
    }
  }

  private func window(
    processIdentifier: pid_t,
    bundleIdentifier: String?,
    applicationName: String,
    title: String
  ) -> WindowItem {
    WindowItem(
      processIdentifier: processIdentifier,
      applicationBundleIdentifier: bundleIdentifier,
      applicationName: applicationName,
      title: title
    )
  }
}
