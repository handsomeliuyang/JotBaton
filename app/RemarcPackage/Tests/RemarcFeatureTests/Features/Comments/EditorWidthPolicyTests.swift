@testable import RemarcFeature
import CoreGraphics
import Foundation
import Testing

@Suite("Editor width policy")
struct EditorWidthPolicyTests {
    @Test("Clamps below minimum to editorMinWidth")
    func clampBelowMinWidth() {
        let clamped = EditorWidthPolicy.clamp(300, visibleScreenWidth: 1440)
        #expect(clamped == WorkspaceMetrics.editorMinWidth)
    }

    @Test("Preserves normal width within valid range")
    func clampWithinRange() {
        let clamped = EditorWidthPolicy.clamp(720, visibleScreenWidth: 1440)
        #expect(clamped == 720)
    }

    @Test("Clamps above screen width to visibleScreenWidth minus 16pt margins")
    func clampAboveScreenWidth() {
        let clamped = EditorWidthPolicy.clamp(2000, visibleScreenWidth: 1440)
        #expect(clamped == 1424)
    }

    @Test("Falls back to available screen width when screen is narrower than editorMinWidth")
    func clampScreenNarrowerThanMinWidth() {
        let clamped = EditorWidthPolicy.clamp(560, visibleScreenWidth: 400)
        #expect(clamped == 384)
    }

    @Test("Handles degenerate screen widths smaller than margins")
    func clampTinyScreenWidth() {
        let clamped = EditorWidthPolicy.clamp(560, visibleScreenWidth: 12)
        #expect(clamped == 12)
    }

    @Test("Loads default width when unset and clamps persisted width to active screen")
    func loadAndSaveWidth() throws {
        let suiteName = "EditorWidthPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            EditorWidthPolicy.loadWidth(from: defaults, visibleScreenWidth: 1440)
                == WorkspaceMetrics.editorDefaultWidth
        )

        EditorWidthPolicy.saveWidth(980, to: defaults)
        #expect(EditorWidthPolicy.loadWidth(from: defaults, visibleScreenWidth: 1440) == 980)
        #expect(EditorWidthPolicy.loadWidth(from: defaults, visibleScreenWidth: 800) == 784)

        defaults.set(-100.0, forKey: EditorWidthPolicy.userDefaultsKey)
        #expect(
            EditorWidthPolicy.loadWidth(from: defaults, visibleScreenWidth: 1440)
                == WorkspaceMetrics.editorDefaultWidth
        )
    }

    @Test("Dragging trailing edge keeps leading edge anchored and stops at min and screen edge")
    func dragTrailingEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = CGRect(x: 440, y: 200, width: 560, height: 400)

        let wider = EditorWidthPolicy.resizedHorizontalFrame(
            edge: .trailing,
            initialFrame: initial,
            deltaX: 120,
            visibleScreenFrame: screen
        )
        #expect(wider.x == 440)
        #expect(wider.width == 680)

        let narrower = EditorWidthPolicy.resizedHorizontalFrame(
            edge: .trailing,
            initialFrame: initial,
            deltaX: -300,
            visibleScreenFrame: screen
        )
        #expect(narrower.x == 440)
        #expect(narrower.width == WorkspaceMetrics.editorMinWidth)

        let cappedAtScreen = EditorWidthPolicy.resizedHorizontalFrame(
            edge: .trailing,
            initialFrame: initial,
            deltaX: 2000,
            visibleScreenFrame: screen
        )
        #expect(cappedAtScreen.x == 440)
        #expect(cappedAtScreen.x + cappedAtScreen.width == screen.maxX - EditorWidthPolicy.screenMargin)
    }

    @Test("Dragging leading edge keeps trailing edge anchored and stops at min and screen edge")
    func dragLeadingEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = CGRect(x: 440, y: 200, width: 560, height: 400)

        let wider = EditorWidthPolicy.resizedHorizontalFrame(
            edge: .leading,
            initialFrame: initial,
            deltaX: -120,
            visibleScreenFrame: screen
        )
        #expect(wider.width == 680)
        #expect(wider.x + wider.width == initial.maxX)

        let narrower = EditorWidthPolicy.resizedHorizontalFrame(
            edge: .leading,
            initialFrame: initial,
            deltaX: 300,
            visibleScreenFrame: screen
        )
        #expect(narrower.width == WorkspaceMetrics.editorMinWidth)
        #expect(narrower.x + narrower.width == initial.maxX)

        let cappedAtScreen = EditorWidthPolicy.resizedHorizontalFrame(
            edge: .leading,
            initialFrame: initial,
            deltaX: -2000,
            visibleScreenFrame: screen
        )
        #expect(cappedAtScreen.x == screen.minX + EditorWidthPolicy.screenMargin)
        #expect(cappedAtScreen.x + cappedAtScreen.width == initial.maxX)
    }

    @Test("Centered reset keeps midpoint and clamps within screen bounds")
    func centeredResetFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let centered = EditorWidthPolicy.centeredHorizontalFrame(
            aroundMidX: 720,
            visibleScreenFrame: screen
        )
        #expect(centered.width == WorkspaceMetrics.editorDefaultWidth)
        #expect(centered.x == 720 - WorkspaceMetrics.editorDefaultWidth / 2)

        let nearLeft = EditorWidthPolicy.centeredHorizontalFrame(
            aroundMidX: 100,
            visibleScreenFrame: screen
        )
        #expect(nearLeft.x == screen.minX + EditorWidthPolicy.screenMargin)
    }

    @Test("Vertical frame caps height to visible screen minus margins")
    func verticalFrameClamping() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 600)

        let capped = EditorWidthPolicy.verticalFrame(
            fittingHeight: 750,
            aroundMidY: 300,
            visibleScreenFrame: screen
        )
        #expect(capped.height == 584)
        #expect(capped.y == 8)
    }
}
