@testable import FeatureCapture
@testable import RemarcFeature
import AppKit
import XCTest

@MainActor
final class ScreenshotClipboardTests: XCTestCase {
    private var storage = TemporaryStorageRoot()
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        storage = TemporaryStorageRoot()
        try storage.install()
        // Never read or replace the user's system clipboard in tests.
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
        storage.remove()
    }

    func testPlainCopyOffersImageFormatsAtOriginalPixelDimensionsWithoutSavingFiles() throws {
        let source = TestImages.solid(width: 401, height: 161, red: 1, green: 0, blue: 0)
        try ScreenshotClipboard.write(source, to: pasteboard)

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let data = try XCTUnwrap(pasteboard.data(forType: type))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.pixelsWide, 401)
            XCTAssertEqual(bitmap.pixelsHigh, 161)
        }
        XCTAssertNotNil(NSImage(pasteboard: pasteboard), "native image paste must work")
        XCTAssertNil(pasteboard.data(forType: .fileURL), "copy pixels, not a temporary file URL")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.url.path), ["images"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: storage.url.appendingPathComponent("images").path).isEmpty)
    }

    func testCopyWaitsForNewestMarksAndCommitsLiveTextWithoutSavingAComment() async throws {
        let session = AnnotationSession(source: TestImages.solid(
            width: 240, height: 100, red: 1, green: 0, blue: 0))
        defer { session.teardown() }
        session.ink = AnnotationInk(red: 0, green: 0, blue: 1)
        session.setDisplayScale(4)
        session.add(AnnotationItem(
            payload: .rect(CGRect(x: 5, y: 5, width: 50, height: 30)),
            ink: session.ink, strokeWidth: 6))
        session.beginText(at: CGPoint(x: 90, y: 10), pointSize: 28)
        session.liveTextProvider = { "HELLO" }

        // Do not wait for the display compositor: output must include both edits.
        try await ScreenshotClipboard.copy(session, to: pasteboard)

        let data = try XCTUnwrap(pasteboard.data(forType: .png))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let output = try XCTUnwrap(bitmap.cgImage)
        XCTAssertEqual(output.width, 240, "stage zoom must not enlarge exported pixels")
        XCTAssertEqual(output.height, 100)
        XCTAssertGreaterThan(TestImages.pixel(output, x: 30, y: 6)[2], 100)
        let hasTextInk = stride(from: 90, to: 225, by: 2).contains { x in
            stride(from: 10, to: 45, by: 2).contains { y in
                TestImages.pixel(output, x: x, y: y)[2] > 100
            }
        }
        XCTAssertTrue(hasTextInk, "the live label must be visible in the copied pixels")
        XCTAssertNil(session.pendingText)
        XCTAssertFalse(session.isFrozen)
        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.url.path), ["images"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: storage.url.appendingPathComponent("images").path).isEmpty)
    }

    func testClipboardFailureIsReportedAndLeavesMarksEditableForRetry() async throws {
        let session = AnnotationSession(source: TestImages.solid(
            width: 80, height: 60, red: 1, green: 0, blue: 0))
        defer { session.teardown() }
        session.add(AnnotationItem(
            payload: .rect(CGRect(x: 5, y: 5, width: 40, height: 30)),
            ink: AnnotationInk.presets[0], strokeWidth: 6))
        do {
            try await ScreenshotClipboard.copy(session, to: RejectingClipboard())
            XCTFail("a refused clipboard write must not be reported as success")
        } catch {
            XCTAssertTrue(error is ScreenshotClipboard.CopyError)
        }
        XCTAssertFalse(session.isFrozen, "failed copy must release the output lock")
        XCTAssertEqual(session.items.count, 1)
        session.undo()
        XCTAssertTrue(session.items.isEmpty, "the editor must still accept changes")
        session.redo()
        try await ScreenshotClipboard.copy(session, to: pasteboard)
        XCTAssertNotNil(pasteboard.data(forType: .png), "retry must succeed")
    }
}

@MainActor
private final class RejectingClipboard: ScreenshotClipboardDestination {
    func clearContents() -> Int { 0 }
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool { false }
}
