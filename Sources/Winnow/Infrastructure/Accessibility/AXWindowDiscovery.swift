import ApplicationServices
import Foundation

final class AXWindowDiscovery: WindowDiscovering, @unchecked Sendable {
  private typealias DiscoveryContinuation = CheckedContinuation<
    [WindowItem],
    Error
  >

  private let systemClient: any AXWindowSystemClient
  private let queue: DispatchQueue
  private let ownProcessIdentifier: pid_t
  private let continuationLock = NSLock()
  private var pendingContinuations: [DiscoveryContinuation] = []
  private var isDiscoveryScheduled = false

  init(
    systemClient: any AXWindowSystemClient = LiveAXWindowSystemClient(),
    queue: DispatchQueue = DispatchQueue(
      label: "app.winnow.accessibility.discovery",
      qos: .userInitiated
    ),
    ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
  ) {
    self.systemClient = systemClient
    self.queue = queue
    self.ownProcessIdentifier = ownProcessIdentifier
  }

  func discoverWindows() async throws -> [WindowItem] {
    try await withCheckedThrowingContinuation { continuation in
      continuationLock.lock()
      pendingContinuations.append(continuation)
      let shouldSchedule = !isDiscoveryScheduled
      isDiscoveryScheduled = true
      continuationLock.unlock()

      guard shouldSchedule else {
        return
      }

      queue.async { [self] in
        let result = Result { try discoverWindowsOnQueue() }

        continuationLock.lock()
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        isDiscoveryScheduled = false
        continuationLock.unlock()

        for continuation in continuations {
          continuation.resume(with: result)
        }
      }
    }
  }

  private func discoverWindowsOnQueue() throws -> [WindowItem] {
    guard systemClient.isProcessTrusted else {
      throw WindowServiceError.accessibilityPermissionRequired
    }

    var discoveredWindows: [WindowItem] = []

    for application in systemClient.runningApplications()
    where Self.shouldInclude(
      application: application,
      ownProcessIdentifier: ownProcessIdentifier
    ) {
      do {
        let windows = try systemClient.windows(
          for: application.processIdentifier
        )
        let eligibleWindows = windows.filter(Self.shouldInclude(window:))
        let titleCounts = Dictionary(
          grouping: eligibleWindows,
          by: {
            $0.title!.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        ).mapValues(\.count)

        discoveredWindows.append(
          contentsOf: eligibleWindows.map { window in
            let title = window.title!.trimmingCharacters(
              in: .whitespacesAndNewlines
            )

            return WindowItem(
              processIdentifier: application.processIdentifier,
              applicationBundleIdentifier: application.bundleIdentifier,
              applicationName: application.localizedName,
              title: title,
              accessibilityIdentifier: window.accessibilityIdentifier,
              sameTitleWindowCount: titleCounts[title, default: 1],
              isMinimized: window.isMinimized,
              accessibilityReference: window.reference
            )
          }
        )
      } catch let error as AXWindowSystemError {
        if Self.isPermissionFailure(error) || !systemClient.isProcessTrusted {
          throw WindowServiceError.accessibilityPermissionRequired
        }

        Self.log(
          error,
          processIdentifier: application.processIdentifier
        )
      }
    }

    guard systemClient.isProcessTrusted else {
      throw WindowServiceError.accessibilityPermissionRequired
    }

    return discoveredWindows.sorted {
      let applicationComparison = $0.applicationName.localizedCaseInsensitiveCompare(
        $1.applicationName
      )
      if applicationComparison != .orderedSame {
        return applicationComparison == .orderedAscending
      }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  static func shouldInclude(
    application: RunningApplicationSnapshot,
    ownProcessIdentifier: pid_t
  ) -> Bool {
    application.processIdentifier != ownProcessIdentifier
      && application.processIdentifier > 0
      && application.isRegularApplication
      && !application.isTerminated
      && !application.localizedName.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
  }

  static func shouldInclude(window: AXWindowSnapshot) -> Bool {
    guard window.role == kAXWindowRole as String else {
      return false
    }

    let excludedSubroles = [
      kAXFloatingWindowSubrole as String,
      kAXSystemFloatingWindowSubrole as String,
    ]
    if let subrole = window.subrole, excludedSubroles.contains(subrole) {
      return false
    }

    return !(window.title ?? "").trimmingCharacters(
      in: .whitespacesAndNewlines
    ).isEmpty
  }

  private static func isPermissionFailure(
    _ error: AXWindowSystemError
  ) -> Bool {
    guard case .accessibility(let axError) = error else {
      return false
    }
    return axError == .apiDisabled
  }

  private static func log(
    _ error: AXWindowSystemError,
    processIdentifier: pid_t
  ) {
    switch error {
    case .accessibility(let axError):
      PrivacyLogger.windowFailure(
        processIdentifier: processIdentifier,
        code: Int(axError.rawValue)
      )
    case .invalidAttributeValue:
      PrivacyLogger.windowFailure(
        processIdentifier: processIdentifier,
        code: -1
      )
    }
  }
}
