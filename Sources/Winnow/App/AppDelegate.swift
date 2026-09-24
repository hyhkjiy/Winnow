import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let environment = AppEnvironment.live()
  private var statusItemController: StatusItemController?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var reconciliationTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    environment.windowEventMonitor.onWindowStateChanged = { [weak self] in
      self?.environment.overlayCoordinator.requestRefresh()
    }
    environment.windowEventMonitor.start()
    let workspaceNotifications: [Notification.Name] = [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification,
      NSWorkspace.activeSpaceDidChangeNotification,
      NSWorkspace.didWakeNotification,
      NSWorkspace.sessionDidBecomeActiveNotification,
    ]
    workspaceObservers = workspaceNotifications.map { name in
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.reconcileWindows() }
      }
    }
    // AX notifications are not guaranteed. Reconcile even when no event arrives.
    reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) {
      [weak self] _ in
      Task { @MainActor in self?.reconcileWindows() }
    }
    reconciliationTimer?.tolerance = 3
    environment.overlayCoordinator.requestRefresh()
    environment.hotKeyManager.onPressed = { [weak self] in
      self?.environment.overlayCoordinator.toggle()
    }

    environment.settingsWindowController.onRequestAccessibility = { [weak self] in
      guard let self else {
        return
      }
      environment.permissionClient.requestAccess()
    }
    environment.settingsWindowController.onRequestScreenCapture = { [weak self] in
      guard let self else {
        return
      }
      environment.screenCapturePermissionClient.requestAccess()
    }

    statusItemController = StatusItemController(
      onToggleOverlay: { [weak self] in
        self?.environment.overlayCoordinator.toggle()
      },
      onOpenSettings: { [weak self] in
        self?.environment.settingsWindowController.show()
      },
      onRequestAccessibility: { [weak self] in
        guard let self else {
          return
        }
        environment.permissionClient.requestAccess()
      },
      onRequestScreenCapture: { [weak self] in
        guard let self else {
          return
        }
        environment.screenCapturePermissionClient.requestAccess()
      },
      onDiscoverWindows: { [weak self] in
        guard let self else {
          return []
        }
        return try await self.environment.windowDiscovery.discoverWindowsForPresentation()
      },
      onActivateWindow: { [weak self] window in
        guard let self else {
          return
        }

        do {
          try await self.environment.windowActivator.activate(window)
        } catch {
          PrivacyLogger.windowFailure(
            processIdentifier: window.processIdentifier,
            code: -1
          )
        }
      }
    )

    let registration = environment.hotKeyManager.registerDefault()
    if case .failure(let status) = registration {
      PrivacyLogger.app.error("Global hot key registration failed with status \(status)")
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    reconciliationTimer?.invalidate()
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    workspaceObservers.removeAll()
    environment.windowEventMonitor.stop()
    environment.hotKeyManager.unregister()
    environment.overlayCoordinator.hide()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    environment.windowEventMonitor.synchronizeRunningApplications()
    guard
      environment.overlayCoordinator.isVisible,
      environment.searchSession.phase == .accessibilityPermissionRequired
    else {
      return
    }
    environment.overlayCoordinator.refreshWindows()
  }

  private func reconcileWindows() {
    environment.windowEventMonitor.synchronizeRunningApplications()
    environment.overlayCoordinator.requestRefresh()
  }
}
