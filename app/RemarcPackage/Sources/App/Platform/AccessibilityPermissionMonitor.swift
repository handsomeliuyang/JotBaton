import CorePlatform
import ApplicationServices
import Foundation

/// Reconnect listeners when macOS grants or revokes access while Remarc is running.
/// A completed onboarding flag does not imply the current binary is still trusted.
@MainActor
final class AccessibilityPermissionMonitor {
    private let isTrusted: () -> Bool
    private var lastTrusted: Bool?
    private var timer: Timer?
    private var onChange: ((Bool) -> Void)?

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }

    func start(onChange: @escaping (Bool) -> Void) {
        stop()
        self.onChange = onChange
        lastTrusted = isTrusted()
        let timer = Timer(timeInterval: PermissionMonitoring.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermission()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onChange = nil
        lastTrusted = nil
    }

    func checkPermission() {
        guard let lastTrusted, onChange != nil else { return }
        let trusted = isTrusted()
        guard trusted != lastTrusted else { return }
        self.lastTrusted = trusted
        onChange?(trusted)
    }
}
