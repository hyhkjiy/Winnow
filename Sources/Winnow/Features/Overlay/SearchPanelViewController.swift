import AppKit
import Combine

@MainActor
final class SearchPanelViewController: NSViewController, NSSearchFieldDelegate {
  var onRequestPrimary: (() -> Void)?

  private let session: SearchSession
  private let searchField = NSSearchField()
  private let statusLabel = NSTextField(
    labelWithString: "Window discovery is ready for the next implementation slice."
  )
  private var cancellables = Set<AnyCancellable>()
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
    rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor

    searchField.placeholderString = "Search windows"
    searchField.delegate = self
    searchField.font = .systemFont(ofSize: 20)
    searchField.translatesAutoresizingMaskIntoConstraints = false

    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .center
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    rootView.addSubview(searchField)
    rootView.addSubview(statusLabel)
    rootView.addGestureRecognizer(
      NSClickGestureRecognizer(target: self, action: #selector(requestPrimary))
    )

    NSLayoutConstraint.activate([
      searchField.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
      searchField.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
      searchField.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
      searchField.heightAnchor.constraint(equalToConstant: 40),
      statusLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
      statusLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
      statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 20),
    ])

    view = rootView
    bindSession()
  }

  func setPrimary(_ isPrimary: Bool) {
    self.isPrimary = isPrimary
    searchField.isEnabled = isPrimary
    searchField.alphaValue = isPrimary ? 1 : 0.72
  }

  func focusSearchField() {
    view.window?.makeFirstResponder(searchField)
  }

  func controlTextDidChange(_ notification: Notification) {
    guard isPrimary else {
      return
    }
    session.query = searchField.stringValue
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
  }

  @objc
  private func requestPrimary() {
    guard !isPrimary else {
      return
    }
    onRequestPrimary?()
  }
}
