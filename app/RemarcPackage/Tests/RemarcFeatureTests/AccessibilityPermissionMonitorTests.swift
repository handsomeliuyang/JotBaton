import Testing
@testable import RemarcFeature

@Suite("Accessibility permission recovery")
@MainActor
struct AccessibilityPermissionMonitorTests {
    @Test("Granting access after launch reconnects once, and revocation is observed")
    func grantAndRevoke() {
        var trusted = false
        var changes: [Bool] = []
        let monitor = AccessibilityPermissionMonitor(isTrusted: { trusted })
        monitor.start { changes.append($0) }
        defer { monitor.stop() }

        monitor.checkPermission()
        #expect(changes.isEmpty)
        trusted = true
        monitor.checkPermission()
        monitor.checkPermission()
        #expect(changes == [true])
        trusted = false
        monitor.checkPermission()
        #expect(changes == [true, false])
    }

    @Test("Stopped monitoring cannot restart listeners after a permission change")
    func stoppedMonitorDoesNotNotify() {
        var trusted = false
        var changes: [Bool] = []
        let monitor = AccessibilityPermissionMonitor(isTrusted: { trusted })
        monitor.start { changes.append($0) }
        monitor.stop()
        trusted = true
        monitor.checkPermission()
        #expect(changes.isEmpty)
    }
}
