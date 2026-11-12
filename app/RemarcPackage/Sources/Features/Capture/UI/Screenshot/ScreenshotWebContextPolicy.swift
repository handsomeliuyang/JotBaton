import FeatureCapture
enum ScreenshotWebContextPolicy {
    static func allowsWebContext(sourceBundleID: String?) -> Bool {
        guard let sourceBundleID else { return false }
        return CaptureConstants.chromiumBundleIDs.contains(sourceBundleID)
    }
}
