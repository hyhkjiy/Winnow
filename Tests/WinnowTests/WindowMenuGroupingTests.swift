import XCTest

@testable import Winnow

final class WindowMenuGroupingTests: XCTestCase {
  func testGroupsWindowsByApplicationAndSortsChildrenByTitle() {
    let windows = [
      window(
        processIdentifier: 20,
        bundleIdentifier: "com.microsoft.VSCode",
        applicationName: "Code",
        title: "Zeta"
      ),
      window(
        processIdentifier: 10,
        bundleIdentifier: "com.dbx.app",
        applicationName: "DBX",
        title: "Second"
      ),
      window(
        processIdentifier: 20,
        bundleIdentifier: "com.microsoft.VSCode",
        applicationName: "Code",
        title: "Alpha"
      ),
      window(
        processIdentifier: 10,
        bundleIdentifier: "com.dbx.app",
        applicationName: "DBX",
        title: "First"
      ),
    ]

    let groups = WindowMenuGrouping.groups(for: windows)

    XCTAssertEqual(groups.map(\.applicationName), ["Code", "DBX"])
    XCTAssertEqual(groups[0].windows.map(\.title), ["Alpha", "Zeta"])
    XCTAssertEqual(groups[1].windows.map(\.title), ["First", "Second"])
  }

  func testKeepsSameNamedApplicationsWithDifferentBundleIdentifiersSeparate() {
    let windows = [
      window(
        processIdentifier: 10,
        bundleIdentifier: "com.example.first",
        applicationName: "Example",
        title: "First"
      ),
      window(
        processIdentifier: 20,
        bundleIdentifier: "com.example.second",
        applicationName: "Example",
        title: "Second"
      ),
    ]

    let groups = WindowMenuGrouping.groups(for: windows)

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups.flatMap(\.windows).count, 2)
  }

  func testCreatesDirectEntryForApplicationWithOneWindow() {
    let onlyWindow = window(
      processIdentifier: 10,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      title: "Project Notes"
    )

    let entries = WindowMenuGrouping.entries(for: [onlyWindow])

    XCTAssertEqual(
      entries,
      [
        .window(
          displayTitle: "Safari — Project Notes",
          window: onlyWindow
        )
      ]
    )
  }

  func testDoesNotRepeatApplicationNameWhenItIsAlsoTheWindowTitle() {
    let onlyWindow = window(
      processIdentifier: 10,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      title: "safari"
    )

    let entries = WindowMenuGrouping.entries(for: [onlyWindow])

    XCTAssertEqual(
      entries,
      [
        .window(
          displayTitle: "Safari",
          window: onlyWindow
        )
      ]
    )
  }

  func testKeepsApplicationSubmenuForMultipleWindows() {
    let firstWindow = window(
      processIdentifier: 10,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      title: "First"
    )
    let secondWindow = window(
      processIdentifier: 10,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      title: "Second"
    )

    let entries = WindowMenuGrouping.entries(
      for: [secondWindow, firstWindow]
    )

    XCTAssertEqual(
      entries,
      [
        .application(
          WindowApplicationGroup(
            applicationName: "Safari",
            windows: [firstWindow, secondWindow]
          )
        )
      ]
    )
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
