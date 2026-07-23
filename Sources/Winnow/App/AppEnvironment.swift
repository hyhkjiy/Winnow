import Foundation

@MainActor
final class AppEnvironment {
  let permissionClient: AccessibilityPermissionClient
  let hotKeyManager: GlobalHotKeyManager
  let searchSession: SearchSession
  let overlayCoordinator: OverlayCoordinator
  let settingsWindowController: SettingsWindowController
  let windowDiscovery: any WindowDiscovering
  let windowActivator: any WindowActivating

  init(
    permissionClient: AccessibilityPermissionClient,
    hotKeyManager: GlobalHotKeyManager,
    searchSession: SearchSession,
    overlayCoordinator: OverlayCoordinator,
    settingsWindowController: SettingsWindowController,
    windowDiscovery: any WindowDiscovering,
    windowActivator: any WindowActivating
  ) {
    self.permissionClient = permissionClient
    self.hotKeyManager = hotKeyManager
    self.searchSession = searchSession
    self.overlayCoordinator = overlayCoordinator
    self.settingsWindowController = settingsWindowController
    self.windowDiscovery = windowDiscovery
    self.windowActivator = windowActivator
  }

  static func live() -> AppEnvironment {
    let permissionClient = AccessibilityPermissionClient()
    let searchSession = SearchSession()
    let accessibilityClient = LiveAXWindowSystemClient()
    let accessibilityQueue = DispatchQueue(
      label: "app.winnow.accessibility",
      qos: .userInitiated
    )
    let windowDiscovery = AXWindowDiscovery(
      systemClient: accessibilityClient,
      queue: accessibilityQueue
    )
    let windowActivator = AXWindowActivator(
      systemClient: accessibilityClient,
      windowDiscovery: windowDiscovery,
      queue: accessibilityQueue
    )

    return AppEnvironment(
      permissionClient: permissionClient,
      hotKeyManager: GlobalHotKeyManager(),
      searchSession: searchSession,
      overlayCoordinator: OverlayCoordinator(session: searchSession),
      settingsWindowController: SettingsWindowController(
        permissionClient: permissionClient
      ),
      windowDiscovery: windowDiscovery,
      windowActivator: windowActivator
    )
  }
}
