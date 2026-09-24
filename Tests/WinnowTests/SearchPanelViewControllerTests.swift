import AppKit
import XCTest

@testable import Winnow

final class SearchPanelViewControllerTests: XCTestCase {
  func testFocusedSearchEditorStaysBetweenSearchAndCancelButtons() async throws {
    try await MainActor.run {
      let controller = SearchPanelViewController(session: SearchSession())
      let panel = SearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
        styleMask: [.borderless], backing: .buffered, defer: false)
      panel.contentViewController = controller
      panel.setContentSize(NSSize(width: 640, height: 240))
      controller.setPrimary(true)
      controller.view.layoutSubtreeIfNeeded()
      let search = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSSearchField }.first)
      let cell = try XCTUnwrap(search.cell as? NSSearchFieldCell)
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        panel.appearance = NSAppearance(named: appearance)
        for query in ["", "中文窗口 " + String(repeating: "long search ", count: 12)] {
          panel.makeFirstResponder(nil)
          search.stringValue = query
          XCTAssertTrue(panel.makeFirstResponder(search))
          let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
          let editorRect = editor.convert(editor.bounds, to: search)
          let textRect = cell.searchTextRect(forBounds: search.bounds)
          XCTAssertEqual(editorRect.minX, textRect.minX, accuracy: 0.5)
          XCTAssertGreaterThanOrEqual(
            editorRect.minX, cell.searchButtonRect(forBounds: search.bounds).maxX)
          XCTAssertLessThanOrEqual(
            editorRect.maxX, cell.cancelButtonRect(forBounds: search.bounds).minX)
        }
      }
      panel.makeFirstResponder(nil)
      panel.contentViewController = nil
    }
  }

  func testLongListFitsVisibleWidthAcrossScrollbarStylesAndPanelResizing() async throws {
    try await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(
        with: (0..<40).map {
          WindowItem(
            processIdentifier: pid_t($0 / 3 + 10), applicationName: "App \($0 / 3)",
            title: "Window \($0) " + String(repeating: "Long title ", count: 20))
        })
      let controller = SearchPanelViewController(session: session)
      let panel = SearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
        styleMask: [.borderless], backing: .buffered, defer: false)
      panel.contentViewController = controller
      let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
      let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
      for style in [NSScroller.Style.legacy, .overlay] {
        scroll.scrollerStyle = style
        for width: CGFloat in [640, 400, 640] {
          panel.setContentSize(NSSize(width: width, height: 500))
          controller.view.layoutSubtreeIfNeeded()
          scroll.tile()
          let group = try XCTUnwrap(session.entries.last)
          let row = outline.row(forItem: group)
          outline.scrollRowToVisible(row)
          outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
          controller.view.layoutSubtreeIfNeeded()
          let rowView = try XCTUnwrap(outline.rowView(atRow: row, makeIfNecessary: true))
          XCTAssertEqual(outline.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
          XCTAssertLessThanOrEqual(rowView.frame.maxX, scroll.contentView.bounds.maxX + 0.5)
          let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true))
          cell.layoutSubtreeIfNeeded()
          let count = try XCTUnwrap(
            cell.subviews.compactMap { $0 as? NSTextField }
              .first { $0.stringValue == "3 windows" })
          XCTAssertGreaterThanOrEqual(count.frame.width, count.intrinsicContentSize.width)
          XCTAssertLessThanOrEqual(
            count.convert(count.bounds, to: outline).maxX,
            scroll.contentView.bounds.maxX)
          XCTAssertEqual(scroll.contentView.bounds.minX, 0)
        }
      }
      panel.contentViewController = nil
    }
  }

  func testReturnTogglesGroupWithoutActivatingAnArbitraryWindow() async {
    await MainActor.run {
      let session = SearchSession()
      let windows = ["First", "Second"].map {
        WindowItem(processIdentifier: 0, applicationName: "Editor", title: $0)
      }
      session.replaceWindows(with: windows)
      let controller = SearchPanelViewController(session: session)
      _ = controller.view
      controller.setPrimary(true)
      var activated: WindowItem?
      controller.onActivateWindow = { activated = $0 }
      let group = session.entries[0]
      session.selectNode(id: group.id)
      let wasExpanded = session.isExpanded(group)

      XCTAssertTrue(
        controller.control(
          NSControl(), textView: NSTextView(),
          doCommandBy: #selector(NSResponder.insertNewline(_:))))
      XCTAssertEqual(session.isExpanded(group), !wasExpanded)
      XCTAssertNil(activated)

      _ = controller.control(
        NSControl(), textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertNewline(_:)))
      XCTAssertEqual(session.isExpanded(group), wasExpanded)
      XCTAssertNil(activated)
      session.selectNode(id: group.children[0].id)
      _ = controller.control(
        NSControl(), textView: NSTextView(),
        doCommandBy: #selector(NSResponder.insertNewline(_:)))
      XCTAssertEqual(activated, windows[0])
    }
  }

  func testSubtitleDoesNotCompressWindowTitleToItsOwnWidth() async {
    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [
        WindowItem(processIdentifier: 0, applicationName: "Finder", title: "Downloads")
      ])
      let controller = SearchPanelViewController(session: session)
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 180),
        styleMask: [.borderless], backing: .buffered, defer: false)
      panel.contentViewController = controller
      panel.setContentSize(NSSize(width: 640, height: 180))
      controller.view.layoutSubtreeIfNeeded()
      let scroll = controller.view.subviews.compactMap { $0 as? NSScrollView }.first!
      let outline = scroll.documentView as! NSOutlineView
      let cell = outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
      cell.layoutSubtreeIfNeeded()
      let title = cell.textField!
      XCTAssertEqual(title.stringValue, "Downloads")
      XCTAssertGreaterThan(title.bounds.width, title.intrinsicContentSize.width)
      panel.contentViewController = nil
    }
  }

  func testFieldEditorPreservesTextEditingAndHandlesNavigationAndEscape() async {
    await MainActor.run {
      let session = SearchSession()
      session.replaceWindows(with: [
        WindowItem(processIdentifier: 0, applicationName: "Editor", title: "First"),
        WindowItem(processIdentifier: 0, applicationName: "Editor", title: "Second"),
      ])
      let controller = SearchPanelViewController(session: session)
      _ = controller.view
      controller.setPrimary(true)
      let search = controller.view.subviews.compactMap { $0 as? NSSearchField }.first!
      search.stringValue = "edit"
      let editor = NSTextView()
      XCTAssertFalse(
        controller.control(
          search, textView: editor,
          doCommandBy: #selector(NSResponder.moveLeft(_:))))
      XCTAssertFalse(
        controller.control(
          search, textView: editor,
          doCommandBy: #selector(NSResponder.moveRight(_:))))
      let selected = session.selectedNodeID
      XCTAssertTrue(
        controller.control(
          search, textView: editor,
          doCommandBy: #selector(NSResponder.moveDown(_:))))
      XCTAssertNotEqual(session.selectedNodeID, selected)
      var cancelled = false
      controller.onCancel = { cancelled = true }
      XCTAssertTrue(
        controller.control(
          search, textView: editor,
          doCommandBy: #selector(NSResponder.cancelOperation(_:))))
      XCTAssertTrue(cancelled)
    }
  }
}
