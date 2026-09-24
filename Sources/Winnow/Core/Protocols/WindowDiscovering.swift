import ApplicationServices
import Foundation

struct WindowDiscoveryReport: Equatable, Sendable {
  let windows: [WindowItem]
  let unavailableApplicationCount: Int
}

protocol WindowDiscovering: Sendable {
  func discoverWindows() async throws -> [WindowItem]
  func discoverWindowsForPresentation() async throws -> [WindowItem]
  func discoverReportForPresentation() async throws -> WindowDiscoveryReport
  func refreshWindowsUsingAccessibilityOnly() async throws -> [WindowItem]
}

extension WindowDiscovering {
  func discoverWindowsForPresentation() async throws -> [WindowItem] {
    try await discoverWindows()
  }

  func discoverReportForPresentation() async throws -> WindowDiscoveryReport {
    WindowDiscoveryReport(
      windows: try await discoverWindowsForPresentation(),
      unavailableApplicationCount: 0
    )
  }

  func refreshWindowsUsingAccessibilityOnly() async throws -> [WindowItem] {
    try await discoverWindows()
  }
}

struct EmptyWindowDiscovery: WindowDiscovering {
  func discoverWindows() async throws -> [WindowItem] {
    []
  }
}

enum WindowServiceError: LocalizedError {
  case notImplemented
  case accessibilityPermissionRequired
  case applicationUnavailable
  case windowReferenceUnavailable
  case windowDiscoveryUnavailable
  case accessibilityFailure(AXError)

  var errorDescription: String? {
    switch self {
    case .notImplemented:
      "The window service is not implemented yet."
    case .accessibilityPermissionRequired:
      "Accessibility permission is required."
    case .applicationUnavailable:
      "The target application is no longer running."
    case .windowReferenceUnavailable:
      "The target window no longer has a valid accessibility reference."
    case .windowDiscoveryUnavailable:
      "Window discovery did not complete and no recent result is available."
    case .accessibilityFailure(let error):
      "The Accessibility operation failed with code \(error.rawValue)."
    }
  }
}
