import ApplicationServices
import Foundation

protocol WindowDiscovering: Sendable {
  func discoverWindows() async throws -> [WindowItem]
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
    case .accessibilityFailure(let error):
      "The Accessibility operation failed with code \(error.rawValue)."
    }
  }
}
