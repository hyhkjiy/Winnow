import Foundation
import XCTest

@testable import Winnow

final class ApplicationHostDiscriminatorTests: XCTestCase {
  func testIncludesTopLevelRegularApplication() {
    XCTAssertTrue(
      includes(
        application(
          name: "ChatGPT",
          bundleIdentifier: "com.openai.codex",
          bundlePath: "/Applications/ChatGPT.app",
          isRegular: true
        )
      )
    )
  }

  func testIncludesThirdPartyAccessoryApplication() {
    XCTAssertTrue(
      includes(
        application(
          name: "v2rayN",
          bundleIdentifier: "2dust.v2rayN",
          bundlePath: "/Applications/v2rayN.app",
          isAccessory: true
        )
      )
    )
  }

  func testExcludesXPCServiceEvenIfItReportsAccessoryPolicy() {
    XCTAssertFalse(
      includes(
        application(
          name: "AutoFill (ChatGPT)",
          bundleIdentifier: "com.apple.SafariPlatformSupport.Helper",
          bundlePath:
            "/System/Library/PrivateFrameworks/SafariPlatformSupport.framework"
            + "/XPCServices/com.apple.SafariPlatformSupport.Helper.xpc",
          isAccessory: true
        )
      )
    )
  }

  func testExcludesNestedHelperApplication() {
    XCTAssertFalse(
      includes(
        application(
          name: "WeChat",
          bundleIdentifier: "com.tencent.flue.WeChatAppEx",
          bundlePath:
            "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app",
          isAccessory: true
        )
      )
    )
  }

  func testExcludesAppleSystemAccessoryApplication() {
    XCTAssertFalse(
      includes(
        application(
          name: "Notification Center",
          bundleIdentifier: "com.apple.notificationcenterui",
          bundlePath: "/System/Library/CoreServices/NotificationCenter.app",
          isAccessory: true
        )
      )
    )
  }

  func testIncludesFinderAsUserFacingSystemAccessory() {
    XCTAssertTrue(
      includes(
        application(
          name: "Finder",
          bundleIdentifier: "com.apple.finder",
          bundlePath: "/System/Library/CoreServices/Finder.app",
          isAccessory: true
        )
      )
    )
  }

  func testExcludesAnotherInstanceOfOwnBundle() {
    XCTAssertFalse(
      ApplicationHostDiscriminator.shouldInclude(
        application: application(
          processIdentifier: 10,
          name: "Winnow",
          bundleIdentifier: "app.winnow.Winnow",
          bundlePath: "/Applications/Winnow.app",
          isRegular: true
        ),
        ownProcessIdentifier: 99,
        ownBundleIdentifier: "app.winnow.Winnow"
      )
    )
  }

  func testExcludesProhibitedApplication() {
    XCTAssertFalse(
      includes(
        application(
          name: "AutoFill (ChatGPT)",
          bundleIdentifier: "com.apple.SafariPlatformSupport.Helper",
          bundlePath:
            "/System/Library/PrivateFrameworks/SafariPlatformSupport.framework"
            + "/XPCServices/com.apple.SafariPlatformSupport.Helper.xpc"
        )
      )
    )
  }

  private func includes(
    _ application: RunningApplicationSnapshot
  ) -> Bool {
    ApplicationHostDiscriminator.shouldInclude(
      application: application,
      ownProcessIdentifier: 99
    )
  }

  private func application(
    processIdentifier: pid_t = 10,
    name: String,
    bundleIdentifier: String?,
    bundlePath: String,
    isRegular: Bool = false,
    isAccessory: Bool = false
  ) -> RunningApplicationSnapshot {
    RunningApplicationSnapshot(
      processIdentifier: processIdentifier,
      bundleIdentifier: bundleIdentifier,
      bundleURL: URL(fileURLWithPath: bundlePath),
      localizedName: name,
      isRegularApplication: isRegular,
      isAccessoryApplication: isAccessory,
      isTerminated: false
    )
  }
}
