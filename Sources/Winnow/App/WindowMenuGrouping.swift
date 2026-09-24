import Foundation

struct WindowApplicationGroup: Equatable {
  let applicationName: String
  let windows: [WindowItem]
}

enum WindowMenuEntry: Equatable {
  case window(displayTitle: String, window: WindowItem)
  case application(WindowApplicationGroup)
}

enum WindowMenuGrouping {
  private struct ApplicationKey: Hashable {
    let bundleIdentifier: String?
    let applicationName: String
    let fallbackProcessIdentifier: pid_t?

    init(window: WindowItem) {
      bundleIdentifier = window.applicationBundleIdentifier
      applicationName = window.applicationName
      fallbackProcessIdentifier =
        window.applicationBundleIdentifier == nil
        ? window.processIdentifier
        : nil
    }
  }

  static func groups(for windows: [WindowItem]) -> [WindowApplicationGroup] {
    Dictionary(grouping: windows, by: ApplicationKey.init)
      .map { key, windows in
        WindowApplicationGroup(
          applicationName: key.applicationName,
          windows: windows.sorted(by: windowComesBefore)
        )
      }
      .sorted(by: groupComesBefore)
  }

  static func entries(for windows: [WindowItem]) -> [WindowMenuEntry] {
    groups(for: windows).map { group in
      guard group.windows.count == 1, let window = group.windows.first else {
        return .application(group)
      }

      return .window(
        displayTitle: directItemTitle(
          applicationName: group.applicationName,
          windowTitle: window.title
        ),
        window: window
      )
    }
  }

  private static func directItemTitle(
    applicationName: String,
    windowTitle: String
  ) -> String {
    guard
      applicationName.localizedCaseInsensitiveCompare(windowTitle)
        != .orderedSame
    else {
      return applicationName
    }

    return "\(applicationName) — \(windowTitle)"
  }

  private static func groupComesBefore(
    _ lhs: WindowApplicationGroup,
    _ rhs: WindowApplicationGroup
  ) -> Bool {
    lhs.applicationName.localizedCaseInsensitiveCompare(rhs.applicationName)
      == .orderedAscending
  }

  private static func windowComesBefore(
    _ lhs: WindowItem,
    _ rhs: WindowItem
  ) -> Bool {
    let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    if titleComparison != .orderedSame {
      return titleComparison == .orderedAscending
    }
    if lhs.processIdentifier != rhs.processIdentifier {
      return lhs.processIdentifier < rhs.processIdentifier
    }
    return (lhs.windowServerIdentifier ?? 0)
      < (rhs.windowServerIdentifier ?? 0)
  }
}
