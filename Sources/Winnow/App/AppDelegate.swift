import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let environment = AppEnvironment.live()
  private var statusItemController: StatusItemController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    environment.hotKeyManager.onPressed = { [weak self] in
      self?.environment.overlayCoordinator.toggle()
    }

    environment.settingsWindowController.onRequestAccessibility = { [weak self] in
      self?.environment.permissionClient.requestAccess()
    }

    statusItemController = StatusItemController(
      onToggleOverlay: { [weak self] in
        self?.environment.overlayCoordinator.toggle()
      },
      onOpenSettings: { [weak self] in
        self?.environment.settingsWindowController.show()
      },
      onRequestAccessibility: { [weak self] in
        self?.environment.permissionClient.requestAccess()
      }
    )

    let registration = environment.hotKeyManager.registerDefault()
    if case .failure(let status) = registration {
      PrivacyLogger.app.error("Global hot key registration failed with status \(status)")
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    environment.hotKeyManager.unregister()
    environment.overlayCoordinator.hide()
  }
}
