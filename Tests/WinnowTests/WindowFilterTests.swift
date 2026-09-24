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

  func testMatchesChineseApplicationByPinyinInitials() {
    let weChat = WindowItem(
      processIdentifier: 3,
      applicationName: "微信",
      title: "文件传输助手"
    )

    XCTAssertEqual(
      WindowFilter.filter([weChat], query: "wx"),
      [weChat]
    )
  }
}
