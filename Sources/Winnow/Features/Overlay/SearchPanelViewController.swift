import AppKit
import Combine

private final class WindowSearchFieldCell: NSSearchFieldCell {
  // Keep the native editing geometry while drawing the search area without a bezel.
  override func draw(withFrame frame: NSRect, in controlView: NSView) {
    drawInterior(withFrame: frame, in: controlView)
  }
}

private final class WindowSearchField: NSSearchField {
  override class var cellClass: AnyClass? {
    get { WindowSearchFieldCell.self }
    set { super.cellClass = newValue }
  }

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

private final class WindowResultsScrollView: NSScrollView {
  override func tile() {
    super.tile()
    guard let table = documentView as? NSTableView else { return }
    let width = contentView.bounds.width
    guard width > 0 else { return }
    if table.frame.width != width {
      table.setFrameSize(NSSize(width: width, height: table.frame.height))
    }
    if let column = table.tableColumns.first, column.width != width {
      column.width = width
    }
  }
}

private final class SearchSurfaceView: NSView {
  override var wantsUpdateLayer: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
  }
}

private final class SearchResultRowView: NSTableRowView {
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
  }
}

private final class SearchResultCell: NSTableCellView {
  let icon = NSImageView()
  let titleLabel = NSTextField(labelWithString: "")
  let detailLabel = NSTextField(labelWithString: "")
  let countLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    icon.imageScaling = .scaleProportionallyDown
    titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
    titleLabel.textColor = .labelColor
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.textColor = .secondaryLabelColor
    countLabel.font = .systemFont(ofSize: 11)
    countLabel.textColor = .secondaryLabelColor
    countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    countLabel.setContentHuggingPriority(.required, for: .horizontal)
    for label in [titleLabel, detailLabel] {
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    let text = NSStackView(views: [titleLabel, detailLabel])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 2
    for child in [icon, text, countLabel] {
      child.translatesAutoresizingMaskIntoConstraints = false
      addSubview(child)
    }
    textField = titleLabel
    imageView = icon
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 24),
      icon.heightAnchor.constraint(equalToConstant: 24),
      text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleLabel.trailingAnchor.constraint(equalTo: text.trailingAnchor),
      detailLabel.trailingAnchor.constraint(equalTo: text.trailingAnchor),
      text.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -12),
      countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
  var onPreferredHeightChange: ((CGFloat) -> Void)?

  private let session: SearchSession
  private let searchField = WindowSearchField()
  private let outlineView = WindowResultsOutlineView()
  private let scrollView = WindowResultsScrollView()
  private let statusContainer = NSView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let shortcutLabel = NSTextField(labelWithString: "")
  private var applicationIcons: [pid_t: NSImage] = [:]
  private let freshnessLabel = NSTextField(labelWithString: "")
  private let statusButton = NSButton()
  private let progressIndicator = NSProgressIndicator()
  private var cancellables = Set<AnyCancellable>()
  private var resultsBottomConstraint: NSLayoutConstraint?
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
    let rootView = SearchSurfaceView()
    rootView.wantsLayer = true
    rootView.layer?.cornerRadius = 16
    rootView.layer?.masksToBounds = true
    rootView.layer?.borderWidth = 1

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
    shortcutLabel.font = .systemFont(ofSize: 11)
    shortcutLabel.textColor = .secondaryLabelColor
    shortcutLabel.lineBreakMode = .byTruncatingTail
    shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(shortcutLabel)
    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(separator)

    let clickRecognizer = NSClickGestureRecognizer(
      target: self,
      action: #selector(requestPrimary)
    )
    clickRecognizer.delaysPrimaryMouseButtonEvents = false
    rootView.addGestureRecognizer(clickRecognizer)

    let resultsBottom = scrollView.bottomAnchor.constraint(
      equalTo: rootView.bottomAnchor, constant: -38)
    resultsBottomConstraint = resultsBottom
    NSLayoutConstraint.activate([
      searchField.leadingAnchor.constraint(
        equalTo: rootView.leadingAnchor,
        constant: 20
      ),
      searchField.trailingAnchor.constraint(
        equalTo: rootView.trailingAnchor,
        constant: -20
      ),
      searchField.topAnchor.constraint(
        equalTo: rootView.topAnchor,
        constant: 20
      ),
      searchField.heightAnchor.constraint(equalToConstant: 36),

      scrollView.leadingAnchor.constraint(
        equalTo: rootView.leadingAnchor,
        constant: 12
      ),
      scrollView.trailingAnchor.constraint(
        equalTo: rootView.trailingAnchor,
        constant: -12
      ),
      scrollView.topAnchor.constraint(
        equalTo: searchField.bottomAnchor,
        constant: 16
      ),
      resultsBottom,
      separator.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
      separator.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
      separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
      shortcutLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
      shortcutLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
      shortcutLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -14),
      freshnessLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
      freshnessLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
      freshnessLabel.bottomAnchor.constraint(equalTo: shortcutLabel.topAnchor, constant: -5),

      statusContainer.leadingAnchor.constraint(
        equalTo: rootView.leadingAnchor,
        constant: 20
      ),
      statusContainer.trailingAnchor.constraint(
        equalTo: rootView.trailingAnchor,
        constant: -20
      ),
      statusContainer.topAnchor.constraint(
        equalTo: searchField.bottomAnchor,
        constant: 16
      ),
      statusContainer.bottomAnchor.constraint(
        equalTo: rootView.bottomAnchor,
        constant: -58
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

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    guard isPrimary else { return false }
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)):
      session.moveSelection(by: 1)
    case #selector(NSResponder.moveUp(_:)):
      session.moveSelection(by: -1)
    case #selector(NSResponder.insertNewline(_:)):
      activateSelectedWindow()
    case #selector(NSResponder.cancelOperation(_:)):
      onCancel?()
    case #selector(NSResponder.moveLeft(_:)) where searchField.stringValue.isEmpty:
      navigateHierarchy(direction: -1)
    case #selector(NSResponder.moveRight(_:)) where searchField.stringValue.isEmpty:
      navigateHierarchy(direction: 1)
    default:
      return false
    }
    return true
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

    let identifier = NSUserInterfaceItemIdentifier("SearchResultCell")
    let cell =
      outlineView.makeView(withIdentifier: identifier, owner: self) as? SearchResultCell
      ?? SearchResultCell(frame: .zero)
    cell.identifier = identifier
    let window = node.window ?? node.children.first?.window
    let isChild = session.parentApplication(of: node.id) != nil
    cell.titleLabel.stringValue =
      node.isApplication
      ? (window?.applicationName ?? node.displayTitle)
      : (window.map { $0.title.isEmpty ? $0.applicationName : $0.title } ?? node.displayTitle)
    cell.titleLabel.font = .systemFont(
      ofSize: node.isApplication ? 12 : 14,
      weight: node.isApplication ? .semibold : .medium)
    cell.titleLabel.textColor = node.isApplication ? .secondaryLabelColor : .labelColor
    var details: [String] = []
    if !node.isApplication, !isChild, let window,
      cell.titleLabel.stringValue != window.applicationName
    {
      details.append(window.applicationName)
    }
    if let window = node.window {
      if window.isMinimized { details.append("Minimized") }
      if case .stale = window.discoveryFreshness { details.append("Last known") }
      if window.discoveryConfidence == .probable { details.append("Likely match") }
      if window.discoveryConfidence == .inventoryOnly { details.append("Limited access") }
    }
    cell.detailLabel.stringValue = details.joined(separator: " · ")
    cell.detailLabel.isHidden = details.isEmpty
    cell.countLabel.stringValue = node.isApplication ? "\(node.children.count) windows" : ""
    cell.icon.image =
      window.flatMap { applicationIcon(for: $0) }
      ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Window")
    cell.toolTip = node.window.map { "\($0.applicationName) — \($0.title)" }
    if let window = node.window, case .stale = window.discoveryFreshness {
      cell.toolTip =
        (cell.toolTip ?? "")
        + "\nThis app did not respond to the latest refresh. Showing its last known window."
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
    updateShortcutHint()
  }

  private func configureSearchField() {
    searchField.placeholderString = "Search windows"
    searchField.delegate = self
    searchField.font = .systemFont(ofSize: 18)
    searchField.isBezeled = true
    searchField.drawsBackground = false
    searchField.focusRingType = .none
    searchField.setAccessibilityLabel("Search windows")
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
    outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    outlineView.autoresizingMask = [.width]
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.allowsEmptySelection = true
    outlineView.allowsMultipleSelection = false
    outlineView.backgroundColor = .clear
    outlineView.focusRingType = .none
    outlineView.style = .plain
    outlineView.indentationPerLevel = 18
    outlineView.intercellSpacing = NSSize(width: 0, height: 2)
    outlineView.rowHeight = 46
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
    scrollView.hasHorizontalScroller = false
    scrollView.horizontalScrollElasticity = .none
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
    updateShortcutHint()
    let resultHeight = (0..<outlineView.numberOfRows).reduce(CGFloat(0)) { height, row in
      guard let item = outlineView.item(atRow: row) else { return height }
      return height + self.outlineView(outlineView, heightOfRowByItem: item) + 2
    }
    let footerHeight: CGFloat = session.unavailableApplicationCount == 0 ? 38 : 58
    resultsBottomConstraint?.constant = -footerHeight
    onPreferredHeightChange?(
      session.contentState == .results
        ? max(180, resultHeight + 72 + footerHeight) : 240)

    let contentState = session.contentState
    freshnessLabel.stringValue =
      "\(session.unavailableApplicationCount) app(s) could not be refreshed. Results may be incomplete."
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

  func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
    SearchResultRowView()
  }

  func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    guard let node = item as? WindowSearchNode else { return 46 }
    return node.isApplication ? 36 : 42
  }

  private func applicationIcon(for window: WindowItem) -> NSImage? {
    if let cached = applicationIcons[window.processIdentifier] { return cached }
    let app = NSRunningApplication(processIdentifier: window.processIdentifier)
    let bundleURL =
      app?.bundleURL
      ?? window.applicationBundleIdentifier.flatMap {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
      }
    let icon = bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? app?.icon
    if let icon { applicationIcons[window.processIdentifier] = icon }
    return icon
  }

  private func updateShortcutHint() {
    shortcutLabel.isHidden = session.contentState != .results
    if let node = session.selectedNode, node.isApplication {
      shortcutLabel.stringValue =
        session.isExpanded(node)
        ? "↑↓ Navigate    ↵ Collapse group    esc Close"
        : "↑↓ Navigate    ↵ Expand group    esc Close"
    } else {
      shortcutLabel.stringValue = "↑↓ Navigate    ↵ Switch window    esc Close"
    }
  }

  private func activateSelectedWindow() {
    if let node = session.selectedNode, node.isApplication {
      session.setApplicationExpanded(nodeID: node.id, expanded: !session.isExpanded(node))
      return
    }
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
      let node = outlineView.item(atRow: row) as? WindowSearchNode
    else {
      return
    }
    session.selectNode(id: node.id)
    activateSelectedWindow()
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
