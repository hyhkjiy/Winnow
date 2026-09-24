import Combine
import Foundation

enum WindowSearchPhase: Equatable {
  case idle
  case loading
  case loaded
  case accessibilityPermissionRequired
  case failed
}

enum WindowSearchContentState: Equatable {
  case idle
  case loading
  case results
  case emptyWindows
  case noMatches
  case accessibilityPermissionRequired
  case failed
}

enum WindowSearchNodeID: Hashable {
  case application(String)
  case window(UUID)
}

final class WindowSearchNode: NSObject {
  enum Kind {
    case application
    case window
  }

  let id: WindowSearchNodeID
  let kind: Kind
  let displayTitle: String
  let window: WindowItem?
  let children: [WindowSearchNode]

  init(
    id: WindowSearchNodeID,
    kind: Kind,
    displayTitle: String,
    window: WindowItem? = nil,
    children: [WindowSearchNode] = []
  ) {
    self.id = id
    self.kind = kind
    self.displayTitle = displayTitle
    self.window = window
    self.children = children
  }

  var isApplication: Bool {
    kind == .application
  }

  var activationWindow: WindowItem? {
    window ?? children.first?.window
  }
}

struct WindowSearchTransliteration {
  let joined: String
  let initials: String
}

final class WindowSearchTransliterationCache {
  let capacity: Int
  private(set) var computationCount = 0
  private var values: [String: WindowSearchTransliteration] = [:]
  private var insertionOrder: [String?]
  private var nextInsertionIndex = 0

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
    insertionOrder = Array(repeating: nil, count: capacity)
  }

  var count: Int {
    values.count
  }

  func transliteration(for value: String) -> WindowSearchTransliteration {
    if let cached = values[value] {
      return cached
    }

    let latin = NSMutableString(string: value)
    CFStringTransform(latin, nil, kCFStringTransformToLatin, false)
    CFStringTransform(latin, nil, kCFStringTransformStripCombiningMarks, false)
    let components = String(latin)
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
    let result = WindowSearchTransliteration(
      joined: components.joined(),
      initials: components.compactMap(\.first).map(String.init).joined()
    )

    if let evicted = insertionOrder[nextInsertionIndex] {
      values.removeValue(forKey: evicted)
    }
    insertionOrder[nextInsertionIndex] = value
    nextInsertionIndex = (nextInsertionIndex + 1) % capacity
    values[value] = result
    computationCount += 1
    return result
  }
}

@MainActor
final class SearchSession: ObservableObject {
  @Published private(set) var query = ""
  @Published private(set) var allWindows: [WindowItem] = []
  @Published private(set) var unavailableApplicationCount = 0
  @Published private(set) var phase: WindowSearchPhase = .idle
  @Published private(set) var entries: [WindowSearchNode] = []
  @Published private(set) var selectedNodeID: WindowSearchNodeID?
  @Published private(set) var collapsedApplicationIDs: Set<WindowSearchNodeID> = []
  let transliterationCache: WindowSearchTransliterationCache

  init(transliterationCacheCapacity: Int = 4_096) {
    transliterationCache = WindowSearchTransliterationCache(
      capacity: transliterationCacheCapacity
    )
  }

  var filteredWindows: [WindowItem] {
    WindowFilter.filter(
      allWindows,
      query: query,
      transliterationCache: transliterationCache
    )
  }

  var visibleNodes: [WindowSearchNode] {
    entries.flatMap { entry in
      guard
        entry.isApplication,
        !collapsedApplicationIDs.contains(entry.id)
      else {
        return [entry]
      }
      return [entry] + entry.children
    }
  }

  var visibleWindows: [WindowItem] {
    entries.flatMap { entry in
      if let window = entry.window {
        return [window]
      }
      return entry.children.compactMap(\.window)
    }
  }

  var selectedNode: WindowSearchNode? {
    guard let selectedNodeID else {
      return nil
    }
    return allNodes.first { $0.id == selectedNodeID }
  }

  var selectedWindowID: UUID? {
    selectedWindow?.id
  }

  var selectedWindow: WindowItem? {
    selectedNode?.activationWindow
  }

  var contentState: WindowSearchContentState {
    switch phase {
    case .idle:
      return .idle
    case .loading:
      return .loading
    case .accessibilityPermissionRequired:
      return .accessibilityPermissionRequired
    case .failed:
      return .failed
    case .loaded:
      if allWindows.isEmpty {
        if unavailableApplicationCount > 0 { return .failed }
        return .emptyWindows
      }
      return visibleWindows.isEmpty ? .noMatches : .results
    }
  }

  func beginLoading(preservingResults: Bool = false) {
    if preservingResults, phase == .loaded, !allWindows.isEmpty {
      return
    }
    phase = .loading
    allWindows = []
    entries = []
    selectedNodeID = nil
    collapsedApplicationIDs = []
  }

  func replaceWindows(with windows: [WindowItem], unavailableApplicationCount: Int = 0) {
    self.unavailableApplicationCount = unavailableApplicationCount
    allWindows = windows
    phase = .loaded
    rebuildEntries()
  }

  func requireAccessibilityPermission() {
    unavailableApplicationCount = 0
    phase = .accessibilityPermissionRequired
    allWindows = []
    entries = []
    selectedNodeID = nil
    collapsedApplicationIDs = []
  }

  func failDiscovery() {
    unavailableApplicationCount = 0
    phase = .failed
    allWindows = []
    entries = []
    selectedNodeID = nil
    collapsedApplicationIDs = []
  }

  func updateQuery(_ query: String) {
    guard self.query != query else {
      return
    }
    self.query = query
    rebuildEntries()
  }

  func selectNode(id: WindowSearchNodeID?) {
    guard selectedNodeID != id else {
      return
    }
    guard let id else {
      selectedNodeID = nil
      return
    }
    guard visibleNodes.contains(where: { $0.id == id }) else {
      return
    }
    selectedNodeID = id
  }

  func selectWindow(id: UUID?) {
    guard let id else {
      selectedNodeID = nil
      return
    }
    guard
      let node = visibleNodes.first(where: { $0.window?.id == id })
    else {
      return
    }
    selectedNodeID = node.id
  }

  func moveSelection(by offset: Int) {
    let nodes = visibleNodes
    guard !nodes.isEmpty, offset != 0 else {
      selectedNodeID = nil
      return
    }

    guard
      let selectedNodeID,
      let currentIndex = nodes.firstIndex(
        where: { $0.id == selectedNodeID }
      )
    else {
      self.selectedNodeID =
        offset > 0 ? nodes.first?.id : nodes.last?.id
      return
    }

    let nextIndex =
      (currentIndex + offset % nodes.count + nodes.count)
      % nodes.count
    self.selectedNodeID = nodes[nextIndex].id
  }

  func isExpanded(_ applicationNode: WindowSearchNode) -> Bool {
    applicationNode.isApplication
      && !collapsedApplicationIDs.contains(applicationNode.id)
  }

  func setApplicationExpanded(
    nodeID: WindowSearchNodeID,
    expanded: Bool
  ) {
    guard
      let applicationNode = entries.first(where: {
        $0.id == nodeID && $0.isApplication
      })
    else {
      return
    }

    if expanded {
      guard collapsedApplicationIDs.contains(nodeID) else {
        return
      }
      collapsedApplicationIDs =
        collapsedApplicationIDs.subtracting([nodeID])
    } else {
      guard !collapsedApplicationIDs.contains(nodeID) else {
        return
      }
      collapsedApplicationIDs =
        collapsedApplicationIDs.union([nodeID])
      if applicationNode.children.contains(where: {
        $0.id == selectedNodeID
      }) {
        selectedNodeID = applicationNode.id
      }
    }
  }

  func parentApplication(
    of nodeID: WindowSearchNodeID
  ) -> WindowSearchNode? {
    entries.first { entry in
      entry.isApplication
        && entry.children.contains(where: { $0.id == nodeID })
    }
  }

  func reset() {
    unavailableApplicationCount = 0
    query = ""
    phase = .idle
    allWindows = []
    entries = []
    selectedNodeID = nil
    collapsedApplicationIDs = []
  }

  private func rebuildEntries() {
    entries = WindowMenuGrouping.entries(for: filteredWindows).map { entry in
      switch entry {
      case .window(let displayTitle, let window):
        return WindowSearchNode(
          id: .window(window.id),
          kind: .window,
          displayTitle: displayTitle,
          window: window
        )
      case .application(let group):
        let applicationID = WindowSearchNodeID.application(
          Self.applicationIdentifier(for: group)
        )
        return WindowSearchNode(
          id: applicationID,
          kind: .application,
          displayTitle: "\(group.applicationName) (\(group.windows.count))",
          children: group.windows.map { window in
            WindowSearchNode(
              id: .window(window.id),
              kind: .window,
              displayTitle: window.title,
              window: window
            )
          }
        )
      }
    }

    let applicationIdentifiers = Set(
      entries.filter(\.isApplication).map(\.id)
    )
    let retainedCollapsedApplicationIDs =
      collapsedApplicationIDs.intersection(applicationIdentifiers)
    if retainedCollapsedApplicationIDs != collapsedApplicationIDs {
      collapsedApplicationIDs = retainedCollapsedApplicationIDs
    }

    let visibleIdentifiers = Set(visibleNodes.map(\.id))
    if let selectedNodeID,
      visibleIdentifiers.contains(selectedNodeID)
    {
      return
    }
    selectedNodeID = visibleNodes.first?.id
  }

  private var allNodes: [WindowSearchNode] {
    entries.flatMap { [$0] + $0.children }
  }

  private static func applicationIdentifier(
    for group: WindowApplicationGroup
  ) -> String {
    guard let firstWindow = group.windows.first else {
      return "name:\(group.applicationName)"
    }
    if let bundleIdentifier = firstWindow.applicationBundleIdentifier {
      return "bundle:\(bundleIdentifier)|name:\(group.applicationName)"
    }
    return
      "pid:\(firstWindow.processIdentifier)|name:\(group.applicationName)"
  }
}

enum WindowFilter {
  static func filter(_ windows: [WindowItem], query: String) -> [WindowItem] {
    filter(
      windows,
      query: query,
      transliterationCache: WindowSearchTransliterationCache(
        capacity: max(1, windows.count * 2)
      )
    )
  }

  static func filter(
    _ windows: [WindowItem],
    query: String,
    transliterationCache: WindowSearchTransliterationCache
  ) -> [WindowItem] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else {
      return windows
    }
    let lowercaseQuery = normalizedQuery.lowercased()

    return windows.filter { window in
      matches(
        window.applicationName,
        query: normalizedQuery,
        lowercaseQuery: lowercaseQuery,
        transliterationCache: transliterationCache
      )
        || matches(
          window.title,
          query: normalizedQuery,
          lowercaseQuery: lowercaseQuery,
          transliterationCache: transliterationCache
        )
    }
  }

  private static func matches(
    _ value: String,
    query: String,
    lowercaseQuery: String,
    transliterationCache: WindowSearchTransliterationCache
  ) -> Bool {
    if value.localizedCaseInsensitiveContains(query) {
      return true
    }

    let transliteration = transliterationCache.transliteration(for: value)
    return transliteration.joined.contains(lowercaseQuery)
      || transliteration.initials.contains(lowercaseQuery)
  }
}
