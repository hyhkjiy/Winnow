import AppKit
import ApplicationServices
import Foundation

@testable import Winnow

final class FakeAXWindowSystemClient: AXWindowSystemClient, @unchecked Sendable {
  private let lock = NSLock()

  var trusted = true
  var applications: [RunningApplicationSnapshot] = []
  var windowsByProcessIdentifier: [pid_t: [AXWindowSnapshot]] = [:]
  var windowErrors: [pid_t: AXWindowSystemError] = [:]
  var invalidRaiseReferences: Set<ObjectIdentifier> = []
  var raiseErrors: [ObjectIdentifier: AXError] = [:]
  var mainErrors: [ObjectIdentifier: AXError] = [:]
  var focusedErrors: [ObjectIdentifier: AXError] = [:]
  var unhideResult = true
  var activationResult = true
  var isOnExpectedQueue: () -> Bool = { true }

  private var recordedEvents: [String] = []
  private var recordedUnexpectedQueueCalls = 0

  var events: [String] {
    lock.withLock { recordedEvents }
  }

  var unexpectedQueueCalls: Int {
    lock.withLock { recordedUnexpectedQueueCalls }
  }

  var isProcessTrusted: Bool {
    record("trust")
    return lock.withLock { trusted }
  }

  func runningApplications() -> [RunningApplicationSnapshot] {
    record("applications")
    return lock.withLock { applications }
  }

  func windows(for processIdentifier: pid_t) throws -> [AXWindowSnapshot] {
    record("windows:\(processIdentifier)")
    return try lock.withLock {
      if let error = windowErrors[processIdentifier] {
        throw error
      }
      return windowsByProcessIdentifier[processIdentifier] ?? []
    }
  }

  func unhideApplication(processIdentifier: pid_t) -> Bool {
    record("unhide:\(processIdentifier)")
    return lock.withLock { unhideResult }
  }

  func activateApplication(processIdentifier: pid_t) -> Bool {
    record("activate:\(processIdentifier)")
    return lock.withLock { activationResult }
  }

  func setWindowMinimized(
    _ reference: AXWindowReference,
    minimized: Bool
  ) throws {
    record("minimized:\(minimized)")
  }

  func raiseWindow(_ reference: AXWindowReference) throws {
    record("raise")
    let identifier = ObjectIdentifier(reference)
    if lock.withLock({ invalidRaiseReferences.contains(identifier) }) {
      throw AXWindowSystemError.accessibility(.invalidUIElement)
    }
    if let error = lock.withLock({ raiseErrors[identifier] }) {
      throw AXWindowSystemError.accessibility(error)
    }
  }

  func setWindowMain(_ reference: AXWindowReference) throws {
    record("main")
    if let error = lock.withLock({ mainErrors[ObjectIdentifier(reference)] }) {
      throw AXWindowSystemError.accessibility(error)
    }
  }

  func setWindowFocused(_ reference: AXWindowReference) throws {
    record("focused")
    if let error = lock.withLock({
      focusedErrors[ObjectIdentifier(reference)]
    }) {
      throw AXWindowSystemError.accessibility(error)
    }
  }

  private func record(_ event: String) {
    lock.withLock {
      recordedEvents.append(event)
      if !isOnExpectedQueue() {
        recordedUnexpectedQueueCalls += 1
      }
    }
  }
}

final class StubWindowDiscovery: WindowDiscovering, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<[WindowItem], Error>
  private var recordedCallCount = 0

  init(result: Result<[WindowItem], Error>) {
    self.result = result
  }

  var callCount: Int {
    lock.withLock { recordedCallCount }
  }

  func discoverWindows() async throws -> [WindowItem] {
    lock.withLock {
      recordedCallCount += 1
    }
    return try result.get()
  }
}

func makeAXReference(processIdentifier: pid_t = 1) -> AXWindowReference {
  AXWindowReference(
    element: AXUIElementCreateApplication(processIdentifier)
  )
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
