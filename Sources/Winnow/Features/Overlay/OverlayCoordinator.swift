import AppKit

@MainActor
final class OverlayCoordinator {
  private struct PanelEntry {
    let panel: SearchPanel
    let controller: SearchPanelViewController
  }

  private let session: SearchSession
  private let onDiscoverWindows: () async throws -> WindowDiscoveryReport
  private let onActivateWindow: (WindowItem) async -> Void
  private let onRequestAccessibility: () -> Void
  private var panels: [CGDirectDisplayID: PanelEntry] = [:]
  private var screenObserver: NSObjectProtocol?
  private var discoveryTask: Task<Void, Never>?
  private var refreshDebounceTask: Task<Void, Never>?
  private var refreshPending = false
  private(set) var cachedWindows: [WindowItem] = []
  private var cacheUpdatedAt: Date?
  private var cachedUnavailableApplicationCount = 0
  private var lastDiscoveryStartedAt: TimeInterval?
  private let hiddenRefreshMinimumInterval: TimeInterval
  private let visibleRefreshDebounceInterval: TimeInterval
  private let uptime: () -> TimeInterval
  private(set) var isVisible = false

  static func panelFrame(
    in visibleFrame: NSRect,
    preferredHeight: CGFloat = 500
  ) -> NSRect {
    let horizontalMargin: CGFloat = 40
    let verticalMargin: CGFloat = 60
    let topInset: CGFloat = 72
    let availableHeight = max(0, visibleFrame.height - verticalMargin * 2)
    let size = NSSize(
      width: min(640, max(320, visibleFrame.width - horizontalMargin * 2)),
      height: min(500, max(180, preferredHeight), availableHeight)
    )
    let origin = NSPoint(
      x: visibleFrame.midX - size.width / 2,
      y: visibleFrame.maxY - topInset - size.height
    )
    return NSRect(origin: origin, size: size)
  }

  init(
    session: SearchSession,
    onDiscoverWindows: @escaping () async throws -> WindowDiscoveryReport,
    onActivateWindow: @escaping (WindowItem) async -> Void,
    onRequestAccessibility: @escaping () -> Void,
    hiddenRefreshMinimumInterval: TimeInterval = 2,
    visibleRefreshDebounceInterval: TimeInterval = 0.15,
    uptime: @escaping () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.session = session
    self.onDiscoverWindows = onDiscoverWindows
    self.onActivateWindow = onActivateWindow
    self.onRequestAccessibility = onRequestAccessibility
    self.hiddenRefreshMinimumInterval = hiddenRefreshMinimumInterval
    self.visibleRefreshDebounceInterval = visibleRefreshDebounceInterval
    self.uptime = uptime
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard self?.isVisible == true else {
          return
        }
        self?.show()
      }
    }
  }

  deinit {
    discoveryTask?.cancel()
    refreshDebounceTask?.cancel()
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
  }

  func toggle() {
    isVisible ? hide() : show()
  }

  func show() {
    let shouldDiscoverWindows = !isVisible
    if shouldDiscoverWindows {
      refreshDebounceTask?.cancel()
      refreshDebounceTask = nil
    }
    hidePanels(resetSession: false)
    isVisible = true

    let screens = NSScreen.screens
    guard !screens.isEmpty else {
      return
    }

    let primaryScreen = screenContainingMouse(in: screens) ?? screens[0]
    for screen in screens {
      let entry = makePanel(for: screen)
      panels[screen.displayID] = entry
      entry.panel.orderFrontRegardless()
    }

    promotePrimary(displayID: primaryScreen.displayID)
    if shouldDiscoverWindows {
      if let cacheUpdatedAt, Date().timeIntervalSince(cacheUpdatedAt) < 10 {
        session.replaceWindows(
          with: cachedWindows, unavailableApplicationCount: cachedUnavailableApplicationCount)
      }
      refreshWindows()
    }
  }

  func hide() {
    refreshDebounceTask?.cancel()
    refreshDebounceTask = nil
    hidePanels(resetSession: true)
  }

  /// Events are hints. Coalesce bursts, then reconcile the window snapshot.
  func requestRefresh() {
    guard discoveryTask == nil else {
      refreshPending = true
      return
    }
    guard refreshDebounceTask == nil else { return }
    let delay = refreshDelay()
    refreshDebounceTask = Task { [weak self] in
      if delay > 0 {
        do {
          try await Task.sleep(
            nanoseconds: UInt64(delay * 1_000_000_000)
          )
        } catch {
          return
        }
      }
      guard !Task.isCancelled, let self else { return }
      self.refreshDebounceTask = nil
      self.refreshWindows()
    }
  }

  func refreshWindows() {
    guard discoveryTask == nil else {
      refreshPending = true
      return
    }
    lastDiscoveryStartedAt = uptime()
    if isVisible {
      session.beginLoading(preservingResults: true)
    }

    discoveryTask = Task { [weak self] in
      guard let self else {
        return
      }
      defer {
        discoveryTask = nil
        if refreshPending {
          refreshPending = false
          requestRefresh()
        }
      }

      do {
        let report = try await onDiscoverWindows()
        let windows = report.windows
        cachedUnavailableApplicationCount = report.unavailableApplicationCount
        guard !Task.isCancelled else { return }
        cachedWindows = windows
        cacheUpdatedAt = Date()
        if isVisible {
          session.replaceWindows(
            with: windows, unavailableApplicationCount: report.unavailableApplicationCount)
        }
      } catch {
        guard !Task.isCancelled else { return }
        cachedWindows = []
        cachedUnavailableApplicationCount = 0
        cacheUpdatedAt = nil
        guard isVisible else { return }

        if case WindowServiceError.accessibilityPermissionRequired = error {
          session.requireAccessibilityPermission()
        } else {
          session.failDiscovery()
        }
      }
    }
  }

  private func refreshDelay() -> TimeInterval {
    if isVisible {
      return visibleRefreshDebounceInterval
    }
    guard let lastDiscoveryStartedAt else {
      return 0
    }
    return max(
      0,
      hiddenRefreshMinimumInterval - (uptime() - lastDiscoveryStartedAt)
    )
  }

  private func hidePanels(resetSession: Bool) {
    for entry in panels.values {
      entry.panel.orderOut(nil)
      entry.panel.close()
    }
    panels.removeAll()
    isVisible = false

    if resetSession {
      session.reset()
    }
  }

  private func makePanel(for screen: NSScreen) -> PanelEntry {
    let frame = Self.panelFrame(in: screen.visibleFrame)
    var preferredHeight = frame.height

    let panel = SearchPanel(
      contentRect: frame,
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false

    let controller = SearchPanelViewController(session: session)
    controller.onRequestPrimary = { [weak self] in
      self?.promotePrimary(displayID: screen.displayID)
    }
    controller.onActivateWindow = { [weak self] window in
      self?.activate(window)
    }
    controller.onRetryDiscovery = { [weak self] in
      self?.refreshWindows()
    }
    controller.onRequestAccessibility = { [weak self] in
      self?.onRequestAccessibility()
    }
    controller.onCancel = { [weak self] in
      self?.hide()
    }
    controller.onPreferredHeightChange = { [weak panel] requestedHeight in
      preferredHeight = requestedHeight
      guard let panel else { return }
      let frame = Self.panelFrame(
        in: screen.visibleFrame,
        preferredHeight: requestedHeight
      )
      panel.setFrame(frame, display: true, animate: false)
    }
    controller.view.frame = NSRect(origin: .zero, size: frame.size)
    panel.contentViewController = controller
    // Installing a content view controller can resize an AppKit window to the
    // controller's initial fitting size. Re-apply the intended screen frame so
    // the panel does not keep the old lower-left origin with a compressed size.
    panel.setFrame(
      Self.panelFrame(
        in: screen.visibleFrame,
        preferredHeight: preferredHeight
      ),
      display: false
    )

    return PanelEntry(panel: panel, controller: controller)
  }

  private func activate(_ window: WindowItem) {
    hide()
    Task {
      await onActivateWindow(window)
    }
  }

  private func promotePrimary(displayID: CGDirectDisplayID) {
    for (candidateDisplayID, entry) in panels {
      let isPrimary = candidateDisplayID == displayID
      entry.controller.setPrimary(isPrimary)

      if isPrimary {
        NSApp.activate()
        entry.panel.makeKeyAndOrderFront(nil)
        entry.controller.focusSearchField()
      }
    }
  }

  private func screenContainingMouse(in screens: [NSScreen]) -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return screens.first { $0.frame.contains(mouseLocation) }
  }
}

extension NSScreen {
  fileprivate var displayID: CGDirectDisplayID {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }
}
