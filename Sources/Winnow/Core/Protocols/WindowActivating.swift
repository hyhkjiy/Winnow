import Foundation

protocol WindowActivating: Sendable {
  func activate(_ window: WindowItem) async throws
}

struct EmptyWindowActivator: WindowActivating {
  func activate(_ window: WindowItem) async throws {
    throw WindowServiceError.notImplemented
  }
}
