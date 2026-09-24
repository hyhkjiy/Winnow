import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct WindowInventorySnapshot: Equatable, Sendable {
  let windowIdentifier: CGWindowID
  let processIdentifier: pid_t
  let applicationBundleIdentifier: String?
  let applicationName: String
  let title: String?
  let frame: CGRect
  let layer: Int
  let isOnScreen: Bool
  let isActive: Bool
}

protocol WindowInventoryClient: Sendable {
  func windows() async throws -> [WindowInventorySnapshot]
  func immediateWindows() -> [WindowInventorySnapshot]
}

extension WindowInventoryClient {
  func immediateWindows() -> [WindowInventorySnapshot] {
    []
  }
}

struct EmptyWindowInventoryClient: WindowInventoryClient {
  func windows() async throws -> [WindowInventorySnapshot] {
    []
  }
}

final class LiveWindowInventoryClient: WindowInventoryClient, @unchecked Sendable {
  typealias ShareableContentRequester = (
    @escaping (SCShareableContent?, Error?) -> Void
  ) -> Void

  private struct CGWindowSnapshot {
    let processIdentifier: pid_t
    let applicationName: String
    let title: String?
    let frame: CGRect?
    let layer: Int
    let isOnScreen: Bool
  }

  private let isScreenCaptureGranted: () -> Bool
  private let regularApplicationProcessIdentifiers: () -> Set<pid_t>
  private let shareableContentTimeout: TimeInterval
  private let shareableContentRetryInterval: TimeInterval
  private let requestShareableContent: ShareableContentRequester
  private let stateLock = NSLock()
  private var shareableContentRetryAfter: Date?
  private var lastKnownScreenCaptureGranted: Bool?

  init(
    permissionClient: ScreenCapturePermissionClient,
    shareableContentTimeout: TimeInterval = 2,
    shareableContentRetryInterval: TimeInterval = 5
  ) {
    self.isScreenCaptureGranted = { permissionClient.isGranted }
    self.regularApplicationProcessIdentifiers = {
      Set<pid_t>(
        NSWorkspace.shared.runningApplications.compactMap { application in
          guard
            application.processIdentifier > 0,
            !application.isTerminated,
            application.activationPolicy == .regular
          else {
            return nil
          }
          return application.processIdentifier
        }
      )
    }
    self.shareableContentTimeout = shareableContentTimeout
    self.shareableContentRetryInterval = shareableContentRetryInterval
    self.requestShareableContent = { completion in
      SCShareableContent.getExcludingDesktopWindows(
        true,
        onScreenWindowsOnly: false,
        completionHandler: completion
      )
    }
  }

  init(
    isScreenCaptureGranted: @escaping () -> Bool,
    shareableContentTimeout: TimeInterval,
    shareableContentRetryInterval: TimeInterval = 5,
    regularApplicationProcessIdentifiers: @escaping () -> Set<pid_t> = { [] },
    requestShareableContent: @escaping ShareableContentRequester
  ) {
    self.isScreenCaptureGranted = isScreenCaptureGranted
    self.regularApplicationProcessIdentifiers = regularApplicationProcessIdentifiers
    self.shareableContentTimeout = shareableContentTimeout
    self.shareableContentRetryInterval = shareableContentRetryInterval
    self.requestShareableContent = requestShareableContent
  }

  func windows() async throws -> [WindowInventorySnapshot] {
    let coreGraphicsWindows = coreGraphicsWindowsByIdentifier()
    let screenCaptureGranted = isScreenCaptureGranted()

    guard
      shouldUseShareableContent(
        screenCaptureGranted: screenCaptureGranted
      )
    else {
      return fallbackWindows(from: coreGraphicsWindows)
    }
    if !screenCaptureGranted {
      PrivacyLogger.app.notice(
        "Screen capture preflight denied; attempting ScreenCaptureKit before falling back"
      )
    }

    let content: SCShareableContent
    do {
      content = try await shareableContent()
    } catch WindowInventoryError.shareableContentTimedOut {
      pauseShareableContent()
      PrivacyLogger.app.error(
        "ScreenCaptureKit window inventory timed out; using Core Graphics during cooldown"
      )
      return fallbackWindows(from: coreGraphicsWindows)
    } catch {
      pauseShareableContent()
      PrivacyLogger.app.error(
        "ScreenCaptureKit window inventory failed; using Core Graphics during cooldown"
      )
      return fallbackWindows(from: coreGraphicsWindows)
    }

    let windows: [WindowInventorySnapshot] = content.windows.compactMap { window in
      guard
        let application = window.owningApplication,
        application.processID > 0
      else {
        return nil
      }

      let cgWindow = coreGraphicsWindows[window.windowID]
      let layer = cgWindow?.layer ?? window.windowLayer
      let frame = cgWindow?.frame ?? window.frame
      guard Self.isPlausibleWindow(frame: frame, layer: layer) else {
        return nil
      }

      return WindowInventorySnapshot(
        windowIdentifier: window.windowID,
        processIdentifier: application.processID,
        applicationBundleIdentifier: application.bundleIdentifier,
        applicationName: application.applicationName,
        title: Self.normalizedTitle(window.title) ?? Self.normalizedTitle(cgWindow?.title),
        frame: frame,
        layer: layer,
        isOnScreen: cgWindow?.isOnScreen ?? window.isOnScreen,
        isActive: window.isActive
      )
    }
    PrivacyLogger.app.info(
      "Window inventory source=ScreenCaptureKit count=\(windows.count, privacy: .public)"
    )
    return windows
  }

  func immediateWindows() -> [WindowInventorySnapshot] {
    fallbackWindows(from: coreGraphicsWindowsByIdentifier())
  }

  private func shareableContent() async throws -> SCShareableContent {
    try await withCheckedThrowingContinuation { continuation in
      let gate = ContinuationGate(continuation: continuation)
      requestShareableContent { content, error in
        if let content {
          gate.resume(returning: content)
        } else {
          gate.resume(
            throwing: error ?? WindowInventoryError.contentUnavailable
          )
        }
      }

      DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + shareableContentTimeout
      ) {
        gate.resume(throwing: WindowInventoryError.shareableContentTimedOut)
      }
    }
  }

  private func fallbackWindows(
    from coreGraphicsWindows: [CGWindowID: CGWindowSnapshot]
  ) -> [WindowInventorySnapshot] {
    let candidates: [WindowInventorySnapshot] = coreGraphicsWindows.compactMap {
      identifier, window in
      guard
        window.processIdentifier > 0,
        !window.applicationName.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty,
        let frame = window.frame,
        Self.isPlausibleWindow(frame: frame, layer: window.layer)
      else {
        return nil
      }

      return WindowInventorySnapshot(
        windowIdentifier: identifier,
        processIdentifier: window.processIdentifier,
        applicationBundleIdentifier: nil,
        applicationName: window.applicationName,
        title: Self.normalizedTitle(window.title),
        frame: frame,
        layer: window.layer,
        isOnScreen: window.isOnScreen,
        isActive: false
      )
    }
    let windows = Self.filteredFallbackWindows(
      candidates,
      regularApplicationProcessIdentifiers: regularApplicationProcessIdentifiers()
    )
    PrivacyLogger.app.info(
      "Window inventory source=CoreGraphics count=\(windows.count, privacy: .public)"
    )
    return windows
  }

  static func filteredFallbackWindows(
    _ candidates: [WindowInventorySnapshot],
    regularApplicationProcessIdentifiers: Set<pid_t>
  ) -> [WindowInventorySnapshot] {
    let eligibleWindows = candidates.filter { window in
      regularApplicationProcessIdentifiers.contains(window.processIdentifier)
        && window.layer == 0
        && window.isOnScreen
        && window.frame.width >= 40
        && window.frame.height >= 40
    }

    return eligibleWindows.sorted {
      let applicationComparison = $0.applicationName.localizedCaseInsensitiveCompare(
        $1.applicationName
      )
      if applicationComparison != .orderedSame {
        return applicationComparison == .orderedAscending
      }
      let titleComparison = ($0.title ?? "").localizedCaseInsensitiveCompare(
        $1.title ?? ""
      )
      if titleComparison != .orderedSame {
        return titleComparison == .orderedAscending
      }
      return $0.windowIdentifier < $1.windowIdentifier
    }
  }

  private func shouldUseShareableContent(
    screenCaptureGranted: Bool
  ) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }

    if lastKnownScreenCaptureGranted != screenCaptureGranted {
      lastKnownScreenCaptureGranted = screenCaptureGranted
      if screenCaptureGranted {
        shareableContentRetryAfter = nil
      }
    }

    guard let shareableContentRetryAfter else {
      return true
    }
    if shareableContentRetryAfter <= Date() {
      self.shareableContentRetryAfter = nil
      return true
    }
    return false
  }

  private func pauseShareableContent() {
    stateLock.lock()
    shareableContentRetryAfter = Date().addingTimeInterval(
      shareableContentRetryInterval
    )
    stateLock.unlock()
  }

  private func coreGraphicsWindowsByIdentifier() -> [CGWindowID: CGWindowSnapshot] {
    let options: CGWindowListOption = [.excludeDesktopElements]
    let rows =
      CGWindowListCopyWindowInfo(options, kCGNullWindowID)
      as? [[String: Any]] ?? []

    var windows: [CGWindowID: CGWindowSnapshot] = [:]
    for row in rows {
      guard
        let rawIdentifier = row[kCGWindowNumber as String] as? NSNumber
      else {
        continue
      }

      let identifier = CGWindowID(rawIdentifier.uint32Value)
      let boundsDictionary = row[kCGWindowBounds as String] as? NSDictionary
      let bounds = boundsDictionary.flatMap {
        CGRect(dictionaryRepresentation: $0)
      }
      windows[identifier] = CGWindowSnapshot(
        processIdentifier: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
        applicationName: row[kCGWindowOwnerName as String] as? String ?? "",
        title: row[kCGWindowName as String] as? String,
        frame: bounds,
        layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
        isOnScreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
      )
    }
    return windows
  }

  private static func normalizedTitle(_ title: String?) -> String? {
    guard let title else {
      return nil
    }
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func isPlausibleWindow(frame: CGRect, layer: Int) -> Bool {
    layer == 0 && frame.width >= 40 && frame.height >= 40
  }
}

enum WindowInventoryError: Error {
  case contentUnavailable
  case shareableContentTimedOut
}

private final class ContinuationGate<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?

  init(continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Value) {
    resume(with: .success(value))
  }

  func resume(throwing error: Error) {
    resume(with: .failure(error))
  }

  private func resume(with result: Result<Value, Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()

    continuation.resume(with: result)
  }
}

final class ScreenCapturePermissionClient: @unchecked Sendable {
  var isGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  @discardableResult
  func requestAccess() -> Bool {
    CGRequestScreenCaptureAccess()
  }
}
