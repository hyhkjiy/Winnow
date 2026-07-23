import Foundation

protocol WindowDiscovering {
  func discoverWindows() async throws -> [WindowItem]
}

struct EmptyWindowDiscovery: WindowDiscovering {
  func discoverWindows() async throws -> [WindowItem] {
    []
  }
}

enum WindowServiceError: LocalizedError {
  case notImplemented

  var errorDescription: String? {
    switch self {
    case .notImplemented:
      "The window service is not implemented yet."
    }
  }
}
