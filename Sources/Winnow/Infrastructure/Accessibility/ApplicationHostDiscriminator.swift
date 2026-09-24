import Foundation

enum ApplicationHostDiscriminator {
  private static let finderBundleIdentifier = "com.apple.finder"

  static func shouldInclude(
    application: RunningApplicationSnapshot,
    ownProcessIdentifier: pid_t,
    ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> Bool {
    guard
      application.processIdentifier > 0,
      application.processIdentifier != ownProcessIdentifier,
      !application.isTerminated,
      application.isRegularApplication
        || application.isAccessoryApplication,
      !application.localizedName.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty,
      let bundleURL = application.bundleURL,
      isTopLevelApplicationBundle(bundleURL)
    else {
      return false
    }

    if let ownBundleIdentifier,
      application.bundleIdentifier == ownBundleIdentifier
    {
      return false
    }

    if application.isAccessoryApplication,
      isAppleSystemAccessory(application)
    {
      return false
    }

    return true
  }

  private static func isTopLevelApplicationBundle(_ bundleURL: URL) -> Bool {
    guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
      return false
    }

    return !bundleURL.standardizedFileURL.deletingLastPathComponent()
      .pathComponents
      .contains { component in
        component.lowercased().hasSuffix(".app")
      }
  }

  private static func isAppleSystemAccessory(
    _ application: RunningApplicationSnapshot
  ) -> Bool {
    guard
      let bundleIdentifier = application.bundleIdentifier,
      bundleIdentifier.hasPrefix("com.apple.")
    else {
      return false
    }

    return bundleIdentifier != finderBundleIdentifier
  }
}
