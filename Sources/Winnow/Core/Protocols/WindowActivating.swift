import Foundation

protocol WindowActivating {
  func activate(_ window: WindowItem) async throws
}

struct EmptyWindowActivator: WindowActivating {
  func activate(_ window: WindowItem) async throws {
    throw WindowServiceError.notImplemented
  }
}
