import Foundation

@MainActor
final class AppEnvironment {
  let permissionClient: AccessibilityPermissionClient
  let screenCapturePermissionClient: ScreenCapturePermissionClient
  let hotKeyManager: GlobalHotKeyManager
  let searchSession: SearchSession
  let overlayCoordinator: OverlayCoordinator
  let settingsWindowController: SettingsWindowController
  let windowDiscovery: any WindowDiscovering
  let windowActivator: any WindowActivating
  let windowEventMonitor: AXWindowEventMonitor

  init(
    permissionClient: AccessibilityPermissionClient,
    screenCapturePermissionClient: ScreenCapturePermissionClient,
    hotKeyManager: GlobalHotKeyManager,
    searchSession: SearchSession,
    overlayCoordinator: OverlayCoordinator,
    settingsWindowController: SettingsWindowController,
    windowDiscovery: any WindowDiscovering,
    windowActivator: any WindowActivating,
    windowEventMonitor: AXWindowEventMonitor
  ) {
    self.permissionClient = permissionClient
    self.screenCapturePermissionClient = screenCapturePermissionClient
    self.hotKeyManager = hotKeyManager
    self.searchSession = searchSession
    self.overlayCoordinator = overlayCoordinator
    self.settingsWindowController = settingsWindowController
    self.windowDiscovery = windowDiscovery
    self.windowActivator = windowActivator
    self.windowEventMonitor = windowEventMonitor
  }

  static func live() -> AppEnvironment {
    let permissionClient = AccessibilityPermissionClient()
    let screenCapturePermissionClient = ScreenCapturePermissionClient()
    let searchSession = SearchSession()
    let accessibilityClient = LiveAXWindowSystemClient()
    let accessibilityQueue = DispatchQueue(
      label: "app.winnow.accessibility",
      qos: .userInitiated
    )
    let windowDiscovery = AXWindowDiscovery(
      systemClient: accessibilityClient,
      inventoryClient: LiveWindowInventoryClient(
        permissionClient: screenCapturePermissionClient
      ),
      queue: accessibilityQueue
    )
    let windowActivator = AXWindowActivator(
      systemClient: accessibilityClient,
      windowDiscovery: windowDiscovery
    )
    let overlayCoordinator = OverlayCoordinator(
      session: searchSession,
      onDiscoverWindows: {
        try await windowDiscovery.discoverReportForPresentation()
      },
      onActivateWindow: { window in
        do {
          try await windowActivator.activate(window)
        } catch {
          PrivacyLogger.windowFailure(
            processIdentifier: window.processIdentifier,
            code: -1
          )
        }
      },
      onRequestAccessibility: {
        permissionClient.requestAccess()
      }
    )

    return AppEnvironment(
      permissionClient: permissionClient,
      screenCapturePermissionClient: screenCapturePermissionClient,
      hotKeyManager: GlobalHotKeyManager(),
      searchSession: searchSession,
      overlayCoordinator: overlayCoordinator,
      settingsWindowController: SettingsWindowController(
        permissionClient: permissionClient,
        screenCapturePermissionClient: screenCapturePermissionClient
      ),
      windowDiscovery: windowDiscovery,
      windowActivator: windowActivator,
      windowEventMonitor: AXWindowEventMonitor()
    )
  }
}
