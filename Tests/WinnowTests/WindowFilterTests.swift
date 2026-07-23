import XCTest

@testable import Winnow

final class WindowFilterTests: XCTestCase {
  private let windows = [
    WindowItem(
      processIdentifier: 1,
      applicationName: "Safari",
      title: "Project Notes"
    ),
    WindowItem(
      processIdentifier: 2,
      applicationName: "Xcode",
      title: "WinnowApp.swift"
    ),
  ]

  func testEmptyQueryReturnsAllWindows() {
    XCTAssertEqual(WindowFilter.filter(windows, query: ""), windows)
  }

  func testMatchesApplicationNameCaseInsensitively() {
    XCTAssertEqual(
      WindowFilter.filter(windows, query: "sAfArI"),
      [windows[0]]
    )
  }

  func testMatchesWindowTitleCaseInsensitively() {
    XCTAssertEqual(
      WindowFilter.filter(windows, query: "winnowapp"),
      [windows[1]]
    )
  }
}
