import AppKit
import ApplicationServices
import Foundation

final class AXWindowEventMonitor: @unchecked Sendable {
  var onWindowStateChanged: (() -> Void)?

  private let queue = DispatchQueue(
    label: "app.winnow.accessibility.observers",
    qos: .utility
  )
  private var observers: [pid_t: AXObserver] = [:]
  private var isStarted = false

  func start() {
    queue.async { [self] in
      startOnQueue()
    }
  }

  func stop() {
    queue.async { [self] in
      stopOnQueue()
    }
  }

  func synchronizeRunningApplications() {
    queue.async { [self] in
      synchronizeRunningApplicationsOnQueue()
    }
  }

  fileprivate func handleNotification() {
    onWindowStateChanged?()
  }

  private func startOnQueue() {
    guard !isStarted else {
      return
    }
    isStarted = true
    synchronizeRunningApplicationsOnQueue()
  }

  private func stopOnQueue() {
    guard isStarted else {
      return
    }
    isStarted = false
    for observer in observers.values {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(observer),
        .commonModes
      )
    }
    observers.removeAll()
  }

  private func synchronizeRunningApplicationsOnQueue() {
    guard isStarted else { return }
    guard AXIsProcessTrusted() else {
      for observer in observers.values {
        CFRunLoopRemoveSource(
          CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes
        )
      }
      observers.removeAll()
      return
    }

    let processIdentifiers = Set<pid_t>(
      NSWorkspace.shared.runningApplications.compactMap { application in
        guard
          application.processIdentifier > 0,
          application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
          !application.isTerminated,
          application.activationPolicy == .regular
            || application.activationPolicy == .accessory
        else {
          return nil
        }
        return application.processIdentifier
      }
    )

    for processIdentifier in observers.keys
    where !processIdentifiers.contains(processIdentifier) {
      guard let observer = observers.removeValue(forKey: processIdentifier) else {
        continue
      }
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(observer),
        .commonModes
      )
    }

    for processIdentifier in processIdentifiers
    where observers[processIdentifier] == nil {
      addObserver(processIdentifier: processIdentifier)
    }
  }

  private func addObserver(processIdentifier: pid_t) {
    var observer: AXObserver?
    let createError = AXObserverCreate(
      processIdentifier,
      axWindowEventCallback,
      &observer
    )
    guard createError == .success, let observer else {
      return
    }

    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.15)
    let context = Unmanaged.passUnretained(self).toOpaque()
    let notifications = [
      kAXWindowCreatedNotification,
      kAXFocusedWindowChangedNotification,
      kAXMainWindowChangedNotification,
    ]
    var registered = false
    for notification in notifications {
      let error = AXObserverAddNotification(
        observer,
        application,
        notification as CFString,
        context
      )
      registered = registered || error == .success
    }

    guard registered else {
      return
    }
    observers[processIdentifier] = observer
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )
  }
}

private func axWindowEventCallback(
  _: AXObserver,
  _: AXUIElement,
  _: CFString,
  context: UnsafeMutableRawPointer?
) {
  guard let context else {
    return
  }
  let monitor = Unmanaged<AXWindowEventMonitor>
    .fromOpaque(context)
    .takeUnretainedValue()
  DispatchQueue.main.async {
    monitor.handleNotification()
  }
}
