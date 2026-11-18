@testable import RemarcFeature
import AppKit
import SwiftUI
import Testing

@Suite("Comment list mouse wheel scrolling")
struct MouseWheelScrollingTests {
    @Test("A detent moves immediately, eases out and reaches its target in 220ms")
    func smoothDeceleration() {
        var motion = MouseWheelScrollMotion()
        motion.retarget(from: 100, by: 90, within: 0...1000, viewport: 400, now: 0)
        let first = motion.position(at: 0.055)
        let second = motion.position(at: 0.110)
        let third = motion.position(at: 0.165)
        #expect(first > 100)
        #expect(first - 100 > second - first)
        #expect(second - first > third - second)
        #expect(motion.position(at: 0.22) == 190)
        #expect(!motion.isActive)
    }

    @Test("Repeated detents accumulate; reversing discards the forward backlog")
    func accumulationAndReversal() {
        var motion = MouseWheelScrollMotion()
        motion.retarget(from: 100, by: 90, within: 0...1000, viewport: 400, now: 0)
        let position = motion.position(at: 0.04)
        motion.retarget(from: position, by: 90, within: 0...1000, viewport: 400, now: 0.04)
        #expect(motion.target == 280)
        motion.retarget(from: position, by: -90, within: 0...1000, viewport: 400, now: 0.04)
        #expect(motion.target == position - 90)
        #expect(motion.position(at: 0.05) < position)
    }

    @Test("Wheel backlog stays within one viewport and never passes document edges")
    func boundaries() {
        var motion = MouseWheelScrollMotion()
        motion.retarget(from: 100, by: 5000, within: 0...1000, viewport: 400, now: 0)
        #expect(motion.target == 500)
        motion.retarget(from: 950, by: 90, within: 0...1000, viewport: 400, now: 1)
        #expect(motion.position(at: 2) == 1000)
        motion.retarget(from: 1000, by: 90, within: 0...1000, viewport: 400, now: 2)
        #expect(!motion.isActive)
        motion.retarget(from: 10, by: -90, within: 0...1000, viewport: 400, now: 3)
        #expect(motion.position(at: 4) == 0)
    }

    @Test("Animation position depends on elapsed time rather than timer frequency")
    func frameRateIndependence() {
        var fast = MouseWheelScrollMotion()
        fast.retarget(from: 0, by: 90, within: 0...1000, viewport: 400, now: 0)
        var slow = fast
        for frame in 1...12 { _ = fast.position(at: Double(frame) / 120) }
        #expect(fast.position(at: 0.11) == slow.position(at: 0.11))
    }

    @Test("Precise input, native momentum and modified/horizontal wheels remain native")
    @MainActor
    func inputClassification() throws {
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                        wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0))
        #expect(MouseWheelScrollingView.shouldSmooth(try #require(NSEvent(cgEvent: wheel))))
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        #expect(!MouseWheelScrollingView.shouldSmooth(try #require(NSEvent(cgEvent: wheel))))
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        wheel.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        #expect(!MouseWheelScrollingView.shouldSmooth(try #require(NSEvent(cgEvent: wheel))))
        wheel.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        #expect(!MouseWheelScrollingView.shouldSmooth(try #require(NSEvent(cgEvent: wheel))))
        wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        wheel.flags = .maskShift
        #expect(!MouseWheelScrollingView.shouldSmooth(try #require(NSEvent(cgEvent: wheel))))
        wheel.flags = []
        wheel.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 6)
        #expect(!MouseWheelScrollingView.shouldSmooth(try #require(NSEvent(cgEvent: wheel))))
    }

    @Test("The bridge attaches inside a real SwiftUI scroll document and moves its clip view")
    @MainActor
    func swiftUIScrollIntegration() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView:
            ScrollView {
                VStack {
                    Color.clear.frame(height: 1600)
                }
                .background(MouseWheelScrolling(commentIDs: []))
            }
            .frame(width: 320, height: 240)
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let bridge = try #require(findBridge(in: hosting))
        defer { bridge.stopMonitoring() }
        let scrollView = try #require(bridge.enclosingScrollView)
        let clip = scrollView.contentView
        let start = clip.bounds.origin.y
        let delta: CGFloat = clip.isFlipped ? 90 : -90
        bridge.scroll(by: delta, in: scrollView, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(70))
        let intermediate = clip.bounds.origin.y
        #expect(abs(intermediate - start) > 0)
        #expect(abs(intermediate - start) < 90)
        try await Task.sleep(for: .milliseconds(220))
        #expect(abs(clip.bounds.origin.y - start - delta) < 0.5)

        // Keyboard/programmatic scrolling must take over without the timer
        // pulling the list back toward an obsolete wheel destination.
        bridge.scroll(by: delta, in: scrollView, reduceMotion: false)
        clip.scroll(to: NSPoint(x: 0, y: start))
        scrollView.reflectScrolledClipView(clip)
        try await Task.sleep(for: .milliseconds(60))
        #expect(abs(clip.bounds.origin.y - start) < 0.5)

        // Reduced Motion keeps the longer wheel step without an animated tail.
        bridge.scroll(by: delta, in: scrollView, reduceMotion: true)
        #expect(abs(clip.bounds.origin.y - start - delta) < 0.5)
    }

    @MainActor
    private func findBridge(in view: NSView) -> MouseWheelScrollingView? {
        if let bridge = view as? MouseWheelScrollingView { return bridge }
        for subview in view.subviews {
            if let bridge = findBridge(in: subview) { return bridge }
        }
        return nil
    }
}
