import ApplicationServices
import Foundation

final class AXWindowActivator: WindowActivating, @unchecked Sendable {
  private let systemClient: any AXWindowSystemClient
  private let windowDiscovery: any WindowDiscovering
  private let queue: DispatchQueue

  init(
    systemClient: any AXWindowSystemClient,
    windowDiscovery: any WindowDiscovering,
    queue: DispatchQueue = DispatchQueue(
      label: "app.winnow.accessibility.activation",
      qos: .userInitiated
    )
  ) {
    self.systemClient = systemClient
    self.windowDiscovery = windowDiscovery
    self.queue = queue
  }

  func activate(_ window: WindowItem) async throws {
    do {
      try await performPreciseActivation(window)
      return
    } catch {
      Self.log(error, processIdentifier: window.processIdentifier)

      guard isInvalidReference(error) else {
        try await performApplicationFallback(
          processIdentifier: window.processIdentifier
        )
        return
      }
    }

    let refreshedWindow: WindowItem?
    do {
      refreshedWindow = try await windowDiscovery.discoverWindows().first {
        $0.processIdentifier == window.processIdentifier
          && $0.applicationName == window.applicationName
          && $0.title == window.title
          && $0.applicationBundleIdentifier
            == window.applicationBundleIdentifier
          && Self.matchesIdentity(candidate: $0, original: window)
      }
    } catch {
      Self.log(error, processIdentifier: window.processIdentifier)
      try await performApplicationFallback(
        processIdentifier: window.processIdentifier
      )
      return
    }

    guard let refreshedWindow else {
      try await performApplicationFallback(
        processIdentifier: window.processIdentifier
      )
      return
    }

    do {
      try await performPreciseActivation(refreshedWindow)
    } catch {
      Self.log(error, processIdentifier: window.processIdentifier)
      try await performApplicationFallback(
        processIdentifier: window.processIdentifier
      )
    }
  }

  private func performPreciseActivation(_ window: WindowItem) async throws {
    try await performOnQueue { [systemClient] in
      guard systemClient.isProcessTrusted else {
        throw WindowServiceError.accessibilityPermissionRequired
      }
      guard let reference = window.accessibilityReference else {
        throw WindowServiceError.windowReferenceUnavailable
      }
      guard
        systemClient.unhideApplication(
          processIdentifier: window.processIdentifier
        )
      else {
        throw WindowServiceError.applicationUnavailable
      }

      try Self.performAXStep(processIdentifier: window.processIdentifier) {
        if window.isMinimized {
          try systemClient.setWindowMinimized(
            reference,
            minimized: false
          )
        }
      }

      guard
        systemClient.activateApplication(
          processIdentifier: window.processIdentifier
        )
      else {
        throw WindowServiceError.applicationUnavailable
      }

      try Self.performAXStep(
        processIdentifier: window.processIdentifier
      ) {
        try systemClient.raiseWindow(reference)
      }
      try Self.performAXStep(
        processIdentifier: window.processIdentifier
      ) {
        try systemClient.setWindowMain(reference)
      }
      try Self.performAXStep(
        processIdentifier: window.processIdentifier
      ) {
        try systemClient.setWindowFocused(reference)
      }
    }
  }

  private func performApplicationFallback(
    processIdentifier: pid_t
  ) async throws {
    try await performOnQueue { [systemClient] in
      _ = systemClient.unhideApplication(
        processIdentifier: processIdentifier
      )
      guard
        systemClient.activateApplication(
          processIdentifier: processIdentifier
        )
      else {
        throw WindowServiceError.applicationUnavailable
      }
    }
  }

  private func performOnQueue<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func isInvalidReference(_ error: Error) -> Bool {
    if case AXWindowSystemError.accessibility(.invalidUIElement) = error {
      return true
    }
    if case WindowServiceError.windowReferenceUnavailable = error {
      return true
    }
    return false
  }

  private static func matchesIdentity(
    candidate: WindowItem,
    original: WindowItem
  ) -> Bool {
    if let identifier = original.accessibilityIdentifier {
      return candidate.accessibilityIdentifier == identifier
    }
    return original.sameTitleWindowCount == 1
      && candidate.sameTitleWindowCount == 1
  }

  private static func performAXStep(
    processIdentifier: pid_t,
    _ operation: () throws -> Void
  ) throws {
    do {
      try operation()
    } catch AXWindowSystemError.accessibility(.invalidUIElement) {
      throw AXWindowSystemError.accessibility(.invalidUIElement)
    } catch AXWindowSystemError.accessibility(.apiDisabled) {
      throw AXWindowSystemError.accessibility(.apiDisabled)
    } catch {
      log(error, processIdentifier: processIdentifier)
    }
  }

  private static func log(_ error: Error, processIdentifier: pid_t) {
    let code: Int
    switch error {
    case AXWindowSystemError.accessibility(let axError):
      code = Int(axError.rawValue)
    case WindowServiceError.accessibilityFailure(let axError):
      code = Int(axError.rawValue)
    case WindowServiceError.accessibilityPermissionRequired:
      code = Int(AXError.apiDisabled.rawValue)
    case WindowServiceError.windowReferenceUnavailable:
      code = Int(AXError.invalidUIElement.rawValue)
    default:
      code = -1
    }

    PrivacyLogger.windowFailure(
      processIdentifier: processIdentifier,
      code: code
    )
  }
}
