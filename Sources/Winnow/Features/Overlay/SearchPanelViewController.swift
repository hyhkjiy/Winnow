import AppKit
import Combine

private final class WindowSearchField: NSSearchField {
  var onMoveSelection: ((Int) -> Void)?
  var onNavigateHierarchy: ((Int) -> Void)?
  var onConfirmSelection: (() -> Void)?
  var onCancel: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123:
      onNavigateHierarchy?(-1)
    case 124:
      onNavigateHierarchy?(1)
    case 125:
      onMoveSelection?(1)
    case 126:
      onMoveSelection?(-1)
    case 36, 76:
      onConfirmSelection?()
    case 53:
      onCancel?()
    default:
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(
      .deviceIndependentFlagsMask
    )
    if modifiers == .command,
      event.charactersIgnoringModifiers?.lowercased() == "a"
    {
      window?.makeFirstResponder(self)
      selectText(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

private final class WindowResultsOutlineView: NSOutlineView {
  var onMoveSelection: ((Int) -> Void)?
  var onNavigateHierarchy: ((Int) -> Void)?
  var onConfirmSelection: (() -> Void)?
  var onCancel: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123:
      onNavigateHierarchy?(-1)
    case 124:
      onNavigateHierarchy?(1)
    case 125:
      onMoveSelection?(1)
    case 126:
      onMoveSelection?(-1)
    case 36, 76:
      onConfirmSelection?()
    case 53:
      onCancel?()
    default:
      super.keyDown(with: event)
    }
  }
}

@MainActor
final class SearchPanelViewController: NSViewController,
  NSSearchFieldDelegate,
  NSOutlineViewDataSource,
  NSOutlineViewDelegate
{
  var onRequestPrimary: (() -> Void)?
  var onActivateWindow: ((WindowItem) -> Void)?
  var onRetryDiscovery: (() -> Void)?
  var onRequestAccessibility: (() -> Void)?
  var onCancel: (() -> Void)?

  private let session: SearchSession
  private let searchField = WindowSearchField()
  private let outlineView = WindowResultsOutlineView()
  private let scrollView = NSScrollView()
  private let statusContainer = NSView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let freshnessLabel = NSTextField(labelWithString: "")
  private let statusButton = NSButton()
  private let progressIndicator = NSProgressIndicator()
  private var cancellables = Set<AnyCancellable>()
  private var renderScheduled = false
  private(set) var isPrimary = false

  init(session: SearchSession) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let rootView = NSView()
    rootView.wantsLayer = true
    rootView.layer?.cornerRadius = 16
    rootView.layer?.masksToBounds = true
    rootView.layer?.backgroundColor =
      NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor

    configureSearchField()
    configureOutlineView()
    configureStatusView()

    rootView.addSubview(searchField)
    rootView.addSubview(scrollView)
    rootView.addSubview(statusContainer)
    freshnessLabel.font = .systemFont(ofSize: 11)
    freshnessLabel.textColor = .secondaryLabelColor
    freshnessLabel.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(freshnessLabel)

    let clickRecognizer = NSClickGestureRecognizer(
      target: self,
      action: #selector(requestPrimary)
    )
    clickRecognizer.delaysPrimaryMouseButtonEvents = false
    rootView.addGestureRecognizer(clickRecognizer)

    NSLayoutConstraint.activate([
      searchField.leadingAnchor.constraint(
        equalTo: rootView.leadingAnchor,
        constant: 24
      ),
      searchField.trailingAnchor.constraint(
        equalTo: rootView.trailingAnchor,
        constant: -24
      ),
      searchField.topAnchor.constraint(
        equalTo: rootView.topAnchor,
        constant: 24
      ),
      searchField.heightAnchor.constraint(equalToConstant: 40),

      scrollView.leadingAnchor.constraint(
        equalTo: rootView.leadingAnchor,
        constant: 16
      ),
      scrollView.trailingAnchor.constraint(
        equalTo: rootView.trailingAnchor,
        constant: -16
      ),
      scrollView.topAnchor.constraint(
        equalTo: searchField.bottomAnchor,
        constant: 14
      ),
      scrollView.bottomAnchor.constraint(
        equalTo: rootView.bottomAnchor,
        constant: -38
      ),
      freshnessLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
      freshnessLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
      freshnessLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12),

      statusContainer.leadingAnchor.constraint(
        equalTo: rootView.leadingAnchor,
        constant: 24
      ),
      statusContainer.trailingAnchor.constraint(
        equalTo: rootView.trailingAnchor,
        constant: -24
      ),
      statusContainer.topAnchor.constraint(
        equalTo: searchField.bottomAnchor,
        constant: 14
      ),
      statusContainer.bottomAnchor.constraint(
        equalTo: rootView.bottomAnchor,
        constant: -38
      ),
    ])

    view = rootView
    bindSession()
    render()
  }

  func setPrimary(_ isPrimary: Bool) {
    self.isPrimary = isPrimary
    searchField.isEnabled = isPrimary
    searchField.alphaValue = isPrimary ? 1 : 0.72
  }

  func focusSearchField() {
    guard isPrimary else {
      return
    }
    makeSearchFieldFirstResponder()
    DispatchQueue.main.async { [weak self] in
      self?.makeSearchFieldFirstResponder()
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    guard isPrimary else {
      return
    }
    session.updateQuery(searchField.stringValue)
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    numberOfChildrenOfItem item: Any?
  ) -> Int {
    guard let item else {
      return session.entries.count
    }
    return (item as? WindowSearchNode)?.children.count ?? 0
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    child index: Int,
    ofItem item: Any?
  ) -> Any {
    guard let item else {
      return session.entries[index]
    }
    guard let node = item as? WindowSearchNode else {
      preconditionFailure("Unexpected search result node")
    }
    return node.children[index]
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    isItemExpandable item: Any
  ) -> Bool {
    (item as? WindowSearchNode)?.isApplication == true
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    shouldSelectItem item: Any
  ) -> Bool {
    item is WindowSearchNode
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    shouldExpandItem item: Any
  ) -> Bool {
    guard let node = item as? WindowSearchNode else {
      return false
    }
    session.setApplicationExpanded(nodeID: node.id, expanded: true)
    return true
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    shouldCollapseItem item: Any
  ) -> Bool {
    guard let node = item as? WindowSearchNode else {
      return false
    }
    session.setApplicationExpanded(nodeID: node.id, expanded: false)
    return true
  }

  func outlineView(
    _ outlineView: NSOutlineView,
    viewFor tableColumn: NSTableColumn?,
    item: Any
  ) -> NSView? {
    guard let node = item as? WindowSearchNode else {
      return nil
    }

    let identifier = NSUserInterfaceItemIdentifier(
      node.isApplication ? "ApplicationResultCell" : "WindowResultCell"
    )
    let cell =
      outlineView.makeView(withIdentifier: identifier, owner: self)
      as? NSTableCellView
      ?? makeResultCell(identifier: identifier)
    cell.textField?.stringValue = confidencePrefixedTitle(for: node)
    cell.textField?.font =
      node.isApplication
      ? .systemFont(ofSize: 14, weight: .semibold)
      : .systemFont(ofSize: 14)
    cell.textField?.textColor =
      node.isApplication ? .labelColor : .secondaryLabelColor
    if let window = node.window, case .stale = window.discoveryFreshness {
      cell.toolTip = "This app did not respond to the latest refresh. Showing its last known window."
    } else {
      cell.toolTip = nil
    }
    return cell
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    let row = outlineView.selectedRow
    guard
      row >= 0,
      let node = outlineView.item(atRow: row) as? WindowSearchNode
    else {
      return
    }
    session.selectNode(id: node.id)
  }

  private func configureSearchField() {
    searchField.placeholderString = "Search windows"
    searchField.delegate = self
    searchField.font = .systemFont(ofSize: 20)
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.onMoveSelection = { [weak self] offset in
      self?.session.moveSelection(by: offset)
    }
    searchField.onNavigateHierarchy = { [weak self] direction in
      self?.navigateHierarchy(direction: direction)
    }
    searchField.onConfirmSelection = { [weak self] in
      self?.activateSelectedWindow()
    }
    searchField.onCancel = { [weak self] in
      self?.onCancel?()
    }
  }

  private func configureOutlineView() {
    let column = NSTableColumn(
      identifier: NSUserInterfaceItemIdentifier("SearchResults")
    )
    column.resizingMask = .autoresizingMask
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.allowsEmptySelection = true
    outlineView.allowsMultipleSelection = false
    outlineView.backgroundColor = .clear
    outlineView.focusRingType = .none
    outlineView.indentationPerLevel = 18
    outlineView.intercellSpacing = NSSize(width: 0, height: 4)
    outlineView.rowHeight = 30
    outlineView.target = self
    outlineView.action = #selector(activateClickedRow)
    outlineView.onMoveSelection = { [weak self] offset in
      self?.session.moveSelection(by: offset)
    }
    outlineView.onNavigateHierarchy = { [weak self] direction in
      self?.navigateHierarchy(direction: direction)
    }
    outlineView.onConfirmSelection = { [weak self] in
      self?.activateSelectedWindow()
    }
    outlineView.onCancel = { [weak self] in
      self?.onCancel?()
    }

    scrollView.documentView = outlineView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
  }

  private func configureStatusView() {
    statusContainer.translatesAutoresizingMaskIntoConstraints = false

    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.alignment = .center
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.font = .systemFont(ofSize: 14)
    statusLabel.maximumNumberOfLines = 2
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    statusButton.bezelStyle = .rounded
    statusButton.target = self
    statusButton.action = #selector(performStatusAction)
    statusButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(
      views: [progressIndicator, statusLabel, statusButton]
    )
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    statusContainer.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(
        equalTo: statusContainer.centerXAnchor
      ),
      stack.centerYAnchor.constraint(
        equalTo: statusContainer.centerYAnchor
      ),
      stack.leadingAnchor.constraint(
        greaterThanOrEqualTo: statusContainer.leadingAnchor
      ),
      stack.trailingAnchor.constraint(
        lessThanOrEqualTo: statusContainer.trailingAnchor
      ),
    ])
  }

  private func bindSession() {
    session.$query
      .removeDuplicates()
      .sink { [weak self] query in
        guard let self, self.searchField.stringValue != query else {
          return
        }
        self.searchField.stringValue = query
      }
      .store(in: &cancellables)

    session.objectWillChange
      .sink { [weak self] in
        guard let self, !self.renderScheduled else { return }
        self.renderScheduled = true
        DispatchQueue.main.async {
          self.renderScheduled = false
          self.render()
        }
      }
      .store(in: &cancellables)
  }

  private func render() {
    outlineView.reloadData()
    for entry in session.entries where entry.isApplication {
      if session.isExpanded(entry) {
        outlineView.expandItem(entry)
      } else {
        outlineView.collapseItem(entry)
      }
    }
    synchronizeSelection()

    let contentState = session.contentState
    freshnessLabel.stringValue = "\(session.unavailableApplicationCount) app(s) could not be refreshed. Results may be incomplete."
    freshnessLabel.isHidden = session.unavailableApplicationCount == 0
    let showsResults = contentState == .results
    scrollView.isHidden = !showsResults
    statusContainer.isHidden = showsResults

    progressIndicator.stopAnimation(nil)
    progressIndicator.isHidden = true
    statusButton.isHidden = true

    switch contentState {
    case .idle:
      statusLabel.stringValue = "Ready"
    case .loading:
      statusLabel.stringValue = "Finding windows…"
      progressIndicator.isHidden = false
      progressIndicator.startAnimation(nil)
    case .results:
      break
    case .emptyWindows:
      statusLabel.stringValue = "No switchable windows found"
    case .noMatches:
      statusLabel.stringValue = "No matching windows"
    case .accessibilityPermissionRequired:
      statusLabel.stringValue =
        "Accessibility permission is required to find windows."
      statusButton.title = "Request Accessibility Permission"
      statusButton.isHidden = false
    case .failed:
      statusLabel.stringValue = "Window discovery failed"
      statusButton.title = "Try Again"
      statusButton.isHidden = false
    }
  }

  private func synchronizeSelection() {
    guard let selectedNodeID = session.selectedNodeID else {
      outlineView.deselectAll(nil)
      return
    }

    for row in 0..<outlineView.numberOfRows {
      guard
        let node = outlineView.item(atRow: row) as? WindowSearchNode,
        node.id == selectedNodeID
      else {
        continue
      }
      if outlineView.selectedRow != row {
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      }
      outlineView.scrollRowToVisible(row)
      return
    }
  }

  private func makeResultCell(
    identifier: NSUserInterfaceItemIdentifier
  ) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.textField = label
    cell.addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
      label.trailingAnchor.constraint(
        equalTo: cell.trailingAnchor,
        constant: -8
      ),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private func confidencePrefixedTitle(
    for node: WindowSearchNode
  ) -> String {
    guard let window = node.window else {
      return node.displayTitle
    }
    if case .stale = window.discoveryFreshness {
      return "\(node.displayTitle) — Last known"
    }

    switch window.discoveryConfidence {
    case .exact:
      return node.displayTitle
    case .probable:
      return "≈ \(node.displayTitle)"
    case .inventoryOnly:
      return "◇ \(node.displayTitle)"
    }
  }

  private func activateSelectedWindow() {
    guard let window = session.selectedWindow else {
      return
    }
    onActivateWindow?(window)
  }

  private func navigateHierarchy(direction: Int) {
    guard let selectedNode = session.selectedNode else {
      return
    }

    if selectedNode.isApplication {
      session.setApplicationExpanded(
        nodeID: selectedNode.id,
        expanded: direction > 0
      )
      return
    }

    guard
      direction < 0,
      let parent = session.parentApplication(of: selectedNode.id)
    else {
      return
    }
    session.selectNode(id: parent.id)
  }

  private func makeSearchFieldFirstResponder() {
    guard isPrimary, let window = view.window else {
      return
    }
    window.makeFirstResponder(searchField)
  }

  @objc
  private func activateClickedRow() {
    let row = outlineView.clickedRow
    guard
      row >= 0,
      let node = outlineView.item(atRow: row) as? WindowSearchNode,
      let window = node.window
    else {
      return
    }
    session.selectWindow(id: window.id)
    onActivateWindow?(window)
  }

  @objc
  private func performStatusAction() {
    switch session.contentState {
    case .accessibilityPermissionRequired:
      onRequestAccessibility?()
    case .failed:
      onRetryDiscovery?()
    default:
      break
    }
  }

  @objc
  private func requestPrimary() {
    guard !isPrimary else {
      return
    }
    onRequestPrimary?()
  }
}
