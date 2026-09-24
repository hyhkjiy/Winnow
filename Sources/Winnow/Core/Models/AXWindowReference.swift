import ApplicationServices
import Foundation

final class AXWindowReference: @unchecked Sendable {
  let element: AXUIElement
  let identityToken: UInt64

  init(element: AXUIElement) {
    self.element = element
    self.identityToken = AXWindowIdentityRegistry.shared.token(for: element)
  }
}

private final class AXWindowIdentityRegistry: @unchecked Sendable {
  static let shared = AXWindowIdentityRegistry()

  private struct Entry {
    let element: AXUIElement
    let token: UInt64
  }

  private let lock = NSLock()
  private let capacity = 4_096
  private var buckets: [CFHashCode: [Entry]] = [:]
  private var insertionOrder: [(hash: CFHashCode, token: UInt64)] = []
  private var nextToken: UInt64 = 1

  func token(for element: AXUIElement) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }

    let hash = CFHash(element)
    if let entry = buckets[hash]?.first(where: { CFEqual($0.element, element) }) {
      return entry.token
    }

    let token = nextToken
    nextToken &+= 1
    if nextToken == 0 {
      nextToken = 1
    }
    buckets[hash, default: []].append(Entry(element: element, token: token))
    insertionOrder.append((hash: hash, token: token))
    evictOldestEntryIfNeeded()
    return token
  }

  private func evictOldestEntryIfNeeded() {
    guard insertionOrder.count > capacity else {
      return
    }
    let oldest = insertionOrder.removeFirst()
    buckets[oldest.hash]?.removeAll { $0.token == oldest.token }
    if buckets[oldest.hash]?.isEmpty == true {
      buckets[oldest.hash] = nil
    }
  }
}
