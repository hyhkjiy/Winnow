import Foundation

struct WindowItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let processIdentifier: pid_t
  let applicationBundleIdentifier: String?
  let applicationName: String
  let title: String
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
      && lhs.accessibilityIdentifier == rhs.accessibilityIdentifier
      && lhs.sameTitleWindowCount == rhs.sameTitleWindowCount
      && lhs.isMinimized == rhs.isMinimized
  }
}
