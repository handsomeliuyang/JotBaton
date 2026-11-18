import AppKit
import SwiftUI

/// Only the comment list opts in. Precise/gesture events retain native physics.
struct MouseWheelScrolling: NSViewRepresentable {
    let commentIDs: [UUID]

    func makeNSView(context: Context) -> MouseWheelScrollingView {
        MouseWheelScrollingView(frame: .zero)
    }

    func updateNSView(_ view: MouseWheelScrollingView, context: Context) {
        if view.commentIDs != commentIDs {
            view.stopAnimation()
            view.commentIDs = commentIDs
        }
    }

    static func dismantleNSView(_ view: MouseWheelScrollingView, coordinator: ()) {
        view.stopMonitoring()
    }
}

/// One retargetable movement, rather than a queue of per-detent animations.
struct MouseWheelScrollMotion {
    static let duration: TimeInterval = 0.22
    private(set) var target: CGFloat = 0
    private var start: CGFloat = 0
    private var startedAt: TimeInterval = 0
    private(set) var isActive = false

    mutating func retarget(from position: CGFloat, by delta: CGFloat,
                           within bounds: ClosedRange<CGFloat>, viewport: CGFloat,
                           now: TimeInterval) {
        let remaining = target - position
        let continuesDirection = isActive && remaining * delta > 0
        let base = continuesDirection ? target : position
        // Bound the backlog to one viewport so a fast wheel cannot leave a
        // long, uncontrollable coast after the user stops.
        let distance = min(max(base + delta - position, -viewport), viewport)
        target = min(max(position + distance, bounds.lowerBound), bounds.upperBound)
        start = position
        startedAt = now
        isActive = abs(target - position) > 0.01
    }

    mutating func position(at now: TimeInterval) -> CGFloat {
        let progress = min(max((now - startedAt) / Self.duration, 0), 1)
        let remaining = 1 - progress
        let position = target + (start - target) * CGFloat(remaining * remaining * remaining)
        if progress >= 1 { isActive = false }
        return position
    }
}

@MainActor
final class MouseWheelScrollingView: NSView {
    var commentIDs: [UUID] = []
    private var monitor: Any?
    private var timer: Timer?
    private var motion = MouseWheelScrollMotion()
    private var lastAppliedPosition: CGFloat?
    private var documentHeight: CGFloat = 0
    private var viewportHeight: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
        motion = MouseWheelScrollMotion()
        lastAppliedPosition = nil
    }

    func stopMonitoring() {
        stopAnimation()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Return nil only when this list actually takes ownership of the wheel.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        guard event.type == .scrollWheel else {
            stopAnimation()
            return event
        }
        guard window.isVisible, !isHiddenOrHasHiddenAncestor,
              let scrollView = enclosingScrollView else { return event }
        let clip = scrollView.contentView
        let point = clip.convert(event.locationInWindow, from: nil)
        guard clip.bounds.contains(point),
              Self.shouldSmooth(event),
              !hasNestedVerticalScrollView(at: event.locationInWindow, in: scrollView)
        else {
            stopAnimation()
            return event
        }
        guard let document = scrollView.documentView,
              document.frame.height > clip.bounds.height else { return event }
        // A conventional three-line wheel detent becomes about 90 points.
        let delta = event.scrollingDeltaY * 30 * (clip.isFlipped ? -1 : 1)
        scroll(by: delta, in: scrollView,
               reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        return nil
    }

    func scroll(by delta: CGFloat, in scrollView: NSScrollView, reduceMotion: Bool) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let height = document.frame.height
        let viewport = clip.bounds.height
        guard height > viewport, viewport > 0 else { return }

        let position = clip.bounds.origin.y
        if let previous = lastAppliedPosition,
           abs(position - previous) > 0.5 || height != documentHeight || viewport != viewportHeight {
            stopAnimation()
        }
        let bounds = document.frame.minY...(document.frame.maxY - viewport)
        motion.retarget(from: position, by: delta, within: bounds,
                        viewport: viewport, now: ProcessInfo.processInfo.systemUptime)
        documentHeight = height
        viewportHeight = viewport
        lastAppliedPosition = position
        if reduceMotion {
            apply(position: motion.target, to: scrollView)
            stopAnimation()
        } else if motion.isActive, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !motion.isActive {
            stopAnimation()
        }
    }

    static func shouldSmooth(_ event: NSEvent) -> Bool {
        !event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty
            && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
            && event.scrollingDeltaY != 0
            && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
    }

    private func hasNestedVerticalScrollView(at point: NSPoint, in scrollView: NSScrollView) -> Bool {
        var hit = scrollView.contentView.hitTest(scrollView.convert(point, from: nil))
        while let view = hit, view !== scrollView {
            if let nested = view as? NSScrollView,
               let document = nested.documentView,
               document.frame.height > nested.contentView.bounds.height + 1 {
                return true
            }
            hit = view.superview
        }
        return false
    }

    private func step() {
        guard let scrollView = enclosingScrollView, let document = scrollView.documentView,
              window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              let previous = lastAppliedPosition,
              abs(scrollView.contentView.bounds.origin.y - previous) <= 0.5,
              document.frame.height == documentHeight,
              scrollView.contentView.bounds.height == viewportHeight else {
            stopAnimation()
            return
        }
        apply(position: motion.position(at: ProcessInfo.processInfo.systemUptime), to: scrollView)
        if !motion.isActive { stopAnimation() }
    }

    private func apply(position: CGFloat, to scrollView: NSScrollView) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: position))
        scrollView.reflectScrolledClipView(clip)
        lastAppliedPosition = clip.bounds.origin.y
    }
}
