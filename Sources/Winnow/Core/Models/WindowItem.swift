import CoreGraphics
import Foundation

enum WindowDiscoveryConfidence: Equatable, Sendable {
  case exact
  case probable
  case inventoryOnly
}

enum WindowIdentity: Hashable, Sendable {
  case windowServer(processIdentifier: pid_t, identifier: CGWindowID)
  case accessibility(processIdentifier: pid_t, token: UInt64)
}

enum WindowStaleReason: Equatable, Sendable {
  case timedOut
  case failed
  case partial
  case scanAlreadyInFlight
}

enum WindowDiscoveryFreshness: Equatable, Sendable {
  case fresh
  case stale(WindowStaleReason)
}

struct WindowItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let processIdentifier: pid_t
  let applicationBundleIdentifier: String?
  let applicationName: String
  let title: String
  let windowServerIdentifier: CGWindowID?
  let frame: CGRect?
  let discoveryConfidence: WindowDiscoveryConfidence
  let identity: WindowIdentity?
  let discoveryFreshness: WindowDiscoveryFreshness
  let accessibilityIdentifier: String?
  let sameTitleWindowCount: Int
  let isMinimized: Bool
  let accessibilityReference: AXWindowReference?

  init(
    id: UUID = UUID(),
    processIdentifier: pid_t,
    applicationBundleIdentifier: String? = nil,
    applicationName: String,
    title: String,
    windowServerIdentifier: CGWindowID? = nil,
    frame: CGRect? = nil,
    discoveryConfidence: WindowDiscoveryConfidence = .exact,
    identity: WindowIdentity? = nil,
    discoveryFreshness: WindowDiscoveryFreshness = .fresh,
    accessibilityIdentifier: String? = nil,
    sameTitleWindowCount: Int = 1,
    isMinimized: Bool = false,
    accessibilityReference: AXWindowReference? = nil
  ) {
    self.id = id
    self.processIdentifier = processIdentifier
    self.applicationBundleIdentifier = applicationBundleIdentifier
    self.applicationName = applicationName
    self.title = title
    self.windowServerIdentifier = windowServerIdentifier
    self.frame = frame
    self.discoveryConfidence = discoveryConfidence
    self.identity = identity
    self.discoveryFreshness = discoveryFreshness
    self.accessibilityIdentifier = accessibilityIdentifier
    self.sameTitleWindowCount = sameTitleWindowCount
    self.isMinimized = isMinimized
    self.accessibilityReference = accessibilityReference
  }

  static func == (lhs: WindowItem, rhs: WindowItem) -> Bool {
    lhs.id == rhs.id
      && lhs.processIdentifier == rhs.processIdentifier
      && lhs.applicationBundleIdentifier == rhs.applicationBundleIdentifier
      && lhs.applicationName == rhs.applicationName
      && lhs.title == rhs.title
      && lhs.windowServerIdentifier == rhs.windowServerIdentifier
      && lhs.frame == rhs.frame
      && lhs.discoveryConfidence == rhs.discoveryConfidence
      && lhs.identity == rhs.identity
      && lhs.discoveryFreshness == rhs.discoveryFreshness
      && lhs.accessibilityIdentifier == rhs.accessibilityIdentifier
      && lhs.sameTitleWindowCount == rhs.sameTitleWindowCount
      && lhs.isMinimized == rhs.isMinimized
  }
}
