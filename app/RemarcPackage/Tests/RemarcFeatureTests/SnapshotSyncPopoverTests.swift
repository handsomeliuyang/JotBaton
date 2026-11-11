import AppKit
import SwiftUI
import Testing
@testable import RemarcFeature

@Suite("iCloud popover initial sizing", .serialized)
@MainActor
struct SnapshotSyncPopoverTests {
    init() { _ = NSApplication.shared }

    @Test("The native popover has its measured content size before it is shown")
    func measuresBeforeShowing() {
        let controller = SnapshotSyncPopoverController()
        controller.prepare(screenSize: CGSize(width: 1440, height: 900), colorScheme: .light) {
            Color.clear.frame(height: 260)
        }
        #expect(!controller.popover.isShown)
        #expect(!controller.popover.animates)
        #expect(controller.documentSize == CGSize(width: 340, height: 292))
        #expect(controller.popover.contentSize == controller.documentSize)
    }

    @Test("A tall panel is scrollable within the display, with no provisional first height")
    func constrainsTallContent() {
        let controller = SnapshotSyncPopoverController()
        controller.prepare(screenSize: CGSize(width: 1440, height: 800), colorScheme: .dark) {
            Color.clear.frame(height: 1400)
        }
        #expect(controller.documentSize.height == 1432)
        #expect(controller.popover.contentSize == CGSize(width: 340, height: 640))
        let scroll = controller.popover.contentViewController?.view as? NSScrollView
        #expect(scroll?.hasVerticalScroller == true)
        #expect(scroll?.documentView?.frame.size == controller.documentSize)
    }

    @Test("Each reopening is measured afresh, allowing the panel to shrink as well as grow")
    func remeasuresNewContent() {
        let controller = SnapshotSyncPopoverController()
        controller.prepare(screenSize: CGSize(width: 280, height: 900), colorScheme: .light) {
            Color.clear.frame(height: 300)
        }
        #expect(controller.popover.contentSize == CGSize(width: 248, height: 332))
        controller.prepare(screenSize: CGSize(width: 280, height: 900), colorScheme: .light) {
            Color.clear.frame(height: 100)
        }
        #expect(controller.popover.contentSize == CGSize(width: 248, height: 132))
        #expect(!controller.popover.animates)
    }
}
