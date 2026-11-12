import FeatureCapture
import AppKit

/// What capture needs from its companion editor. The application supplies the
/// concrete composer; capture never reaches into a comment controller singleton.
@MainActor
protocol ScreenshotComposer: AnyObject {
    var frozenStageEdge: StageDockEdge? { get }
    var panelLayoutReady: Bool { get }
    var onPanelLayoutReady: (() -> Void)? { get set }
    var annotationPanelReserve: CGFloat { get }
    func repositionForScreenshot(captureRect: CGRect, restoreFocus: Bool)
    func orderOutForSystemDialog()
    func beginAnnotationAnchoring(displayRectScreen rect: CGRect)
    func setAnnotationDisplayRect(_ rect: CGRect?)
    func focusCommentField()
    func endAnnotationAnchoring()
}
