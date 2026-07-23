import Foundation

struct WindowItem: Identifiable, Equatable, Sendable {
  let id: UUID
  let processIdentifier: pid_t
  let applicationName: String
  let title: String
  let isMinimized: Bool

  init(
    id: UUID = UUID(),
    processIdentifier: pid_t,
    applicationName: String,
    title: String,
    isMinimized: Bool = false
  ) {
    self.id = id
    self.processIdentifier = processIdentifier
    self.applicationName = applicationName
    self.title = title
    self.isMinimized = isMinimized
  }
}
