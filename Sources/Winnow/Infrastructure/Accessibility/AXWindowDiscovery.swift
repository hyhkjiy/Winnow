import ApplicationServices
import Foundation

private enum PIDScanOutcome {
  case success([AXWindowSnapshot])
  case timedOut
  case failed(permissionFailure: Bool)
  case alreadyInFlight
}

private final class PIDScanAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = true
  private var outcomes: [pid_t: PIDScanOutcome] = [:]

  func record(_ outcome: PIDScanOutcome, for processIdentifier: pid_t) {
    lock.lock()
    if isOpen {
      outcomes[processIdentifier] = outcome
    }
    lock.unlock()
  }

  func close(expectedProcessIdentifiers: [pid_t]) -> [pid_t: PIDScanOutcome] {
    lock.lock()
    isOpen = false
    var result = outcomes
    lock.unlock()
    for processIdentifier in expectedProcessIdentifiers
    where result[processIdentifier] == nil {
      result[processIdentifier] = .timedOut
    }
    return result
  }
}

private final class PIDScanCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var isResolved = false

  func beginIfPending() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isResolved else {
      return false
    }
    return true
  }

  func resolve() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isResolved else {
      return false
    }
    isResolved = true
    return true
  }
}

final class AXWindowDiscovery: WindowDiscovering, @unchecked Sendable {
  private enum InventoryMode {
    case screenCapture
    case immediateCoreGraphics
    case none
  }

  private struct ProcessCacheEntry {
    let windows: [WindowItem]
    let refreshedAt: Date
  }

  private struct DiscoveryResult {
    let windows: [WindowItem]
    let unavailableApplicationCount: Int
  }

  private let systemClient: any AXWindowSystemClient
  private let inventoryClient: any WindowInventoryClient
  private let queue: DispatchQueue
  private let scanQueue: OperationQueue
  private let ownProcessIdentifier: pid_t
  private let ownBundleIdentifier: String?
  private let perProcessBudget: TimeInterval
  private let batchBudget: TimeInterval
  private let staleRetention: TimeInterval

  private let activeScanLock = NSLock()
  private var activeProcessIdentifiers: Set<pid_t> = []
  private var cacheByProcessIdentifier: [pid_t: ProcessCacheEntry] = [:]
  private var stableIDsByIdentity: [WindowIdentity: UUID] = [:]

  init(
    systemClient: any AXWindowSystemClient = LiveAXWindowSystemClient(),
    inventoryClient: any WindowInventoryClient = EmptyWindowInventoryClient(),
    queue: DispatchQueue = DispatchQueue(
      label: "app.winnow.accessibility.discovery",
      qos: .userInitiated
    ),
    ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
    ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
    perProcessBudget: TimeInterval = 0.45,
    batchBudget: TimeInterval = 0.8,
    staleRetention: TimeInterval = 5,
    maximumConcurrentProcessScans: Int = 4
  ) {
    self.systemClient = systemClient
    self.inventoryClient = inventoryClient
    self.queue = queue
    self.ownProcessIdentifier = ownProcessIdentifier
    self.ownBundleIdentifier = ownBundleIdentifier
    self.perProcessBudget = perProcessBudget
    self.batchBudget = batchBudget
    self.staleRetention = staleRetention

    let scanQueue = OperationQueue()
    scanQueue.name = "app.winnow.accessibility.process-scans"
    scanQueue.qualityOfService = .userInitiated
    scanQueue.maxConcurrentOperationCount = max(1, maximumConcurrentProcessScans)
    self.scanQueue = scanQueue
  }

  func discoverWindows() async throws -> [WindowItem] {
    try await discover(inventoryMode: .screenCapture).windows
  }

  func discoverWindowsForPresentation() async throws -> [WindowItem] {
    try await discoverReportForPresentation().windows
  }

  func discoverReportForPresentation() async throws -> WindowDiscoveryReport {
    let result = try await discover(inventoryMode: .immediateCoreGraphics)
    return WindowDiscoveryReport(
      windows: result.windows.filter { $0.accessibilityReference != nil },
      unavailableApplicationCount: result.unavailableApplicationCount
    )
  }

  func refreshWindowsUsingAccessibilityOnly() async throws -> [WindowItem] {
    try await discover(inventoryMode: .none).windows
  }

  private func discover(
    inventoryMode: InventoryMode
  ) async throws -> DiscoveryResult {
    let screenCaptureInventory: [WindowInventorySnapshot]?
    switch inventoryMode {
    case .screenCapture:
      screenCaptureInventory = try? await inventoryClient.windows()
    case .immediateCoreGraphics, .none:
      screenCaptureInventory = nil
    }

    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        let inventory: [WindowInventorySnapshot]?
        switch inventoryMode {
        case .screenCapture:
          inventory = screenCaptureInventory
        case .immediateCoreGraphics:
          inventory = inventoryClient.immediateWindows()
        case .none:
          inventory = nil
        }

        continuation.resume(
          with: Result {
            try discoverWindowsOnQueue(
              inventory: inventory,
              includeInventoryOnly: inventoryMode == .screenCapture
            )
          }
        )
      }
    }
  }

  private func discoverWindowsOnQueue(
    inventory: [WindowInventorySnapshot]?,
    includeInventoryOnly: Bool
  ) throws -> DiscoveryResult {
    guard systemClient.isProcessTrusted else {
      throw WindowServiceError.accessibilityPermissionRequired
    }

    let applications = systemClient.runningApplications().filter {
      ApplicationHostDiscriminator.shouldInclude(
        application: $0,
        ownProcessIdentifier: ownProcessIdentifier,
        ownBundleIdentifier: ownBundleIdentifier
      )
    }
    let outcomes = scanApplications(applications)
    let unavailableApplicationCount = outcomes.values.reduce(into: 0) {
      count, outcome in
      if case .success = outcome {
        return
      }
      count += 1
    }

    guard systemClient.isProcessTrusted else {
      throw WindowServiceError.accessibilityPermissionRequired
    }
    let now = Date()
    let runningProcessIdentifiers = Set(applications.map(\.processIdentifier))
    cacheByProcessIdentifier = cacheByProcessIdentifier.filter {
      runningProcessIdentifiers.contains($0.key)
    }
    stableIDsByIdentity = stableIDsByIdentity.filter { identity, _ in
      switch identity {
      case .windowServer(let processIdentifier, _),
        .accessibility(let processIdentifier, _):
        return runningProcessIdentifiers.contains(processIdentifier)
      }
    }

    let eligibleInventory = (inventory ?? []).filter {
      $0.processIdentifier != ownProcessIdentifier
        && runningProcessIdentifiers.contains($0.processIdentifier)
        && $0.layer == 0
        && $0.frame.width >= 40
        && $0.frame.height >= 40
    }
    let inventoryByProcessIdentifier = Dictionary(
      grouping: eligibleInventory,
      by: \.processIdentifier
    )

    var discoveredWindows: [WindowItem] = []
    var usedInventoryIdentifiers: Set<CGWindowID> = []
    var successfulProcessCount = 0
    var staleWindowCount = 0

    for application in applications {
      let processIdentifier = application.processIdentifier
      switch outcomes[processIdentifier] ?? .timedOut {
      case .success(let snapshots):
        successfulProcessCount += 1
        let windows = makeAXWindows(
          application: application,
          snapshots: snapshots,
          inventory: inventoryByProcessIdentifier[processIdentifier] ?? [],
          usedInventoryIdentifiers: &usedInventoryIdentifiers
        )
        cacheByProcessIdentifier[processIdentifier] = ProcessCacheEntry(
          windows: windows,
          refreshedAt: now
        )
        discoveredWindows.append(contentsOf: windows)
      case .timedOut:
        let stale = staleWindows(
          processIdentifier: processIdentifier,
          reason: .timedOut,
          now: now
        )
        staleWindowCount += stale.count
        markInventoryIdentifiersUsed(by: stale, in: &usedInventoryIdentifiers)
        discoveredWindows.append(contentsOf: stale)
      case .failed:
        let stale = staleWindows(
          processIdentifier: processIdentifier,
          reason: .failed,
          now: now
        )
        staleWindowCount += stale.count
        markInventoryIdentifiersUsed(by: stale, in: &usedInventoryIdentifiers)
        discoveredWindows.append(contentsOf: stale)
      case .alreadyInFlight:
        let stale = staleWindows(
          processIdentifier: processIdentifier,
          reason: .scanAlreadyInFlight,
          now: now
        )
        staleWindowCount += stale.count
        markInventoryIdentifiersUsed(by: stale, in: &usedInventoryIdentifiers)
        discoveredWindows.append(contentsOf: stale)
      }
    }

    if !applications.isEmpty,
      successfulProcessCount == 0,
      staleWindowCount == 0
    {
      throw WindowServiceError.windowDiscoveryUnavailable
    }

    if includeInventoryOnly {
      let applicationsByProcessIdentifier = Dictionary(
        uniqueKeysWithValues: applications.map {
          ($0.processIdentifier, $0)
        }
      )
      for inventoryWindow in eligibleInventory
      where !usedInventoryIdentifiers.contains(inventoryWindow.windowIdentifier) {
        guard
          let application =
            applicationsByProcessIdentifier[inventoryWindow.processIdentifier]
        else {
          continue
        }
        let identity = WindowIdentity.windowServer(
          processIdentifier: inventoryWindow.processIdentifier,
          identifier: inventoryWindow.windowIdentifier
        )
        discoveredWindows.append(
          WindowItem(
            id: stableID(for: identity),
            processIdentifier: inventoryWindow.processIdentifier,
            applicationBundleIdentifier:
              application.bundleIdentifier
              ?? inventoryWindow.applicationBundleIdentifier,
            applicationName: application.localizedName,
            title:
              Self.normalizedTitle(inventoryWindow.title)
              ?? application.localizedName,
            windowServerIdentifier: inventoryWindow.windowIdentifier,
            frame: inventoryWindow.frame,
            discoveryConfidence: .inventoryOnly,
            identity: identity,
            accessibilityReference: nil
          )
        )
      }
    }

    let result = addTitleCountsAndSort(discoveredWindows)
    let retainedIdentities = Set(
      result.compactMap(\.identity)
        + cacheByProcessIdentifier.values
          .filter { now.timeIntervalSince($0.refreshedAt) <= staleRetention }
          .flatMap { $0.windows.compactMap(\.identity) }
    )
    stableIDsByIdentity = stableIDsByIdentity.filter {
      retainedIdentities.contains($0.key)
    }
    return DiscoveryResult(
      windows: result,
      unavailableApplicationCount: unavailableApplicationCount
    )
  }

  private func scanApplications(
    _ applications: [RunningApplicationSnapshot]
  ) -> [pid_t: PIDScanOutcome] {
    let accumulator = PIDScanAccumulator()
    let group = DispatchGroup()

    for application in applications {
      let processIdentifier = application.processIdentifier
      guard claimScan(for: processIdentifier) else {
        accumulator.record(.alreadyInFlight, for: processIdentifier)
        continue
      }

      group.enter()
      let completion = PIDScanCompletion()
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + perProcessBudget
      ) {
        if completion.resolve() {
          accumulator.record(.timedOut, for: processIdentifier)
          group.leave()
        }
      }

      scanQueue.addOperation { [self] in
        guard completion.beginIfPending() else {
          releaseScan(for: processIdentifier)
          return
        }
        let outcome: PIDScanOutcome
        do {
          outcome = .success(
            try systemClient.windows(for: processIdentifier)
          )
        } catch let error as AXWindowSystemError {
          Self.log(error, processIdentifier: processIdentifier)
          outcome = .failed(
            permissionFailure: Self.isPermissionFailure(error)
          )
        } catch {
          outcome = .failed(permissionFailure: false)
        }

        releaseScan(for: processIdentifier)
        if completion.resolve() {
          accumulator.record(outcome, for: processIdentifier)
          group.leave()
        }
      }
    }

    _ = group.wait(timeout: .now() + batchBudget)
    return accumulator.close(
      expectedProcessIdentifiers: applications.map(\.processIdentifier)
    )
  }

  private func claimScan(for processIdentifier: pid_t) -> Bool {
    activeScanLock.lock()
    defer { activeScanLock.unlock() }
    return activeProcessIdentifiers.insert(processIdentifier).inserted
  }

  private func releaseScan(for processIdentifier: pid_t) {
    activeScanLock.lock()
    activeProcessIdentifiers.remove(processIdentifier)
    activeScanLock.unlock()
  }

  private func makeAXWindows(
    application: RunningApplicationSnapshot,
    snapshots: [AXWindowSnapshot],
    inventory: [WindowInventorySnapshot],
    usedInventoryIdentifiers: inout Set<CGWindowID>
  ) -> [WindowItem] {
    var locallyUsedInventoryIndexes: Set<Int> = []
    var seenRealWindowIdentifiers: Set<CGWindowID> = []
    return snapshots.filter(Self.shouldInclude(window:)).compactMap { snapshot in
      if let identifier = snapshot.windowServerIdentifier,
        !seenRealWindowIdentifiers.insert(identifier).inserted
      {
        return nil
      }
      let normalizedTitle = Self.normalizedTitle(snapshot.title)
      let title = normalizedTitle ?? application.localizedName
      let identity: WindowIdentity
      let confidence: WindowDiscoveryConfidence
      let realWindowIdentifier = snapshot.windowServerIdentifier
      let matchedInventory: WindowInventorySnapshot?

      if let realWindowIdentifier {
        identity = .windowServer(
          processIdentifier: application.processIdentifier,
          identifier: realWindowIdentifier
        )
        confidence = .exact
        matchedInventory = inventory.first {
          $0.windowIdentifier == realWindowIdentifier
        }
        usedInventoryIdentifiers.insert(realWindowIdentifier)
      } else {
        identity = .accessibility(
          processIdentifier: application.processIdentifier,
          token: snapshot.reference.identityToken
        )
        confidence = .probable
        let matchIndex = Self.bestHeuristicInventoryMatch(
          title: normalizedTitle,
          frame: snapshot.frame,
          inventory: inventory,
          excluding: locallyUsedInventoryIndexes
        )
        matchedInventory = matchIndex.map { inventory[$0] }
        if let matchIndex {
          locallyUsedInventoryIndexes.insert(matchIndex)
          usedInventoryIdentifiers.insert(inventory[matchIndex].windowIdentifier)
        }
      }

      return WindowItem(
        id: stableID(for: identity),
        processIdentifier: application.processIdentifier,
        applicationBundleIdentifier: application.bundleIdentifier,
        applicationName: application.localizedName,
        title: title,
        windowServerIdentifier: realWindowIdentifier,
        frame: snapshot.frame ?? matchedInventory?.frame,
        discoveryConfidence: confidence,
        identity: identity,
        accessibilityIdentifier: snapshot.accessibilityIdentifier,
        isMinimized: snapshot.isMinimized,
        accessibilityReference: snapshot.reference
      )
    }
  }

  private func markInventoryIdentifiersUsed(
    by windows: [WindowItem],
    in identifiers: inout Set<CGWindowID>
  ) {
    for window in windows {
      if let identifier = window.windowServerIdentifier {
        identifiers.insert(identifier)
      }
    }
  }

  private func stableID(for identity: WindowIdentity) -> UUID {
    if let existing = stableIDsByIdentity[identity] {
      return existing
    }
    let identifier = UUID()
    stableIDsByIdentity[identity] = identifier
    return identifier
  }

  private func staleWindows(
    processIdentifier: pid_t,
    reason: WindowStaleReason,
    now: Date
  ) -> [WindowItem] {
    guard
      let entry = cacheByProcessIdentifier[processIdentifier],
      now.timeIntervalSince(entry.refreshedAt) <= staleRetention
    else {
      cacheByProcessIdentifier[processIdentifier] = nil
      return []
    }
    return entry.windows.map { window in
      Self.copy(window, freshness: .stale(reason))
    }
  }

  private func addTitleCountsAndSort(_ windows: [WindowItem]) -> [WindowItem] {
    let titleCounts = Dictionary(
      grouping: windows,
      by: { "\($0.processIdentifier):\($0.title)" }
    ).mapValues(\.count)
    return windows.map { window in
      Self.copy(
        window,
        sameTitleWindowCount:
          titleCounts["\(window.processIdentifier):\(window.title)", default: 1]
      )
    }.sorted {
      let applicationComparison = $0.applicationName.localizedCaseInsensitiveCompare(
        $1.applicationName
      )
      if applicationComparison != .orderedSame {
        return applicationComparison == .orderedAscending
      }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  private static func copy(
    _ window: WindowItem,
    freshness: WindowDiscoveryFreshness? = nil,
    sameTitleWindowCount: Int? = nil
  ) -> WindowItem {
    WindowItem(
      id: window.id,
      processIdentifier: window.processIdentifier,
      applicationBundleIdentifier: window.applicationBundleIdentifier,
      applicationName: window.applicationName,
      title: window.title,
      windowServerIdentifier: window.windowServerIdentifier,
      frame: window.frame,
      discoveryConfidence: window.discoveryConfidence,
      identity: window.identity,
      discoveryFreshness: freshness ?? window.discoveryFreshness,
      accessibilityIdentifier: window.accessibilityIdentifier,
      sameTitleWindowCount: sameTitleWindowCount ?? window.sameTitleWindowCount,
      isMinimized: window.isMinimized,
      accessibilityReference: window.accessibilityReference
    )
  }

  static func shouldInclude(window: AXWindowSnapshot) -> Bool {
    guard window.role == kAXWindowRole as String else {
      return false
    }
    if let frame = window.frame,
      frame.width <= 100 || frame.height <= 50
    {
      return false
    }
    let standardSubroles = [
      kAXStandardWindowSubrole as String,
      kAXDialogSubrole as String,
    ]
    if let subrole = window.subrole,
      standardSubroles.contains(subrole)
    {
      return true
    }
    let excludedSubroles = [
      kAXFloatingWindowSubrole as String,
      kAXSystemFloatingWindowSubrole as String,
    ]
    if let subrole = window.subrole,
      excludedSubroles.contains(subrole)
    {
      return false
    }
    return window.supportsRaiseAction && window.hasWindowControls
  }

  private static func normalizedTitle(_ title: String?) -> String? {
    guard let title else {
      return nil
    }
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func bestHeuristicInventoryMatch(
    title: String?,
    frame: CGRect?,
    inventory: [WindowInventorySnapshot],
    excluding usedIndexes: Set<Int>
  ) -> Int? {
    let matchingIndexes = inventory.indices.filter { index in
      !usedIndexes.contains(index)
        && normalizedTitle(inventory[index].title) == title
    }
    guard matchingIndexes.count > 1, let frame else {
      return matchingIndexes.first
    }
    return matchingIndexes.min {
      frameDistance(frame, inventory[$0].frame)
        < frameDistance(frame, inventory[$1].frame)
    }
  }

  private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    abs(lhs.origin.x - rhs.origin.x)
      + abs(lhs.origin.y - rhs.origin.y)
      + abs(lhs.width - rhs.width)
      + abs(lhs.height - rhs.height)
  }

  private static func isPermissionFailure(_ error: AXWindowSystemError) -> Bool {
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
    case .deadlineExceeded:
      PrivacyLogger.windowFailure(
        processIdentifier: processIdentifier,
        code: Int(AXError.cannotComplete.rawValue)
      )
    }
  }
}
