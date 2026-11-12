@testable import CoreLocalization
@testable import FeatureCapture
@testable import FeatureOnboarding
@testable import RemarcFeature
import Foundation
import XCTest

final class PermissionOnboardingContractTests: XCTestCase {
    private var repositoryRoot: URL {
        let url = RepositoryPaths.repository()
        return url
    }

    func testRelocationFinishesBeforeAppSetupStarts() throws {
        let source = try read("app/RemarcPackage/Sources/App/RemarcApplicationDelegate.swift")

        XCTAssertTrue(source.contains("func applicationWillFinishLaunching"))
        XCTAssertTrue(source.contains("let moveStarted = AppMover.moveIfNecessary()"))
        XCTAssertTrue(source.contains("let installedCopyIsAlreadyRunning = installedRemarcCopyIsAlreadyRunning"))
        XCTAssertTrue(source.contains("shouldSkipSetup = moveStarted || installedCopyIsAlreadyRunning"))
        XCTAssertTrue(source.contains("guard !Self.isInApplicationsDirectory(Bundle.main.bundleURL)"))
        XCTAssertTrue(source.contains("application.processIdentifier != currentProcessIdentifier"))
        XCTAssertTrue(source.contains("return Self.isInApplicationsDirectory(bundleURL)"))
        XCTAssertTrue(source.contains("if !moveStarted && installedCopyIsAlreadyRunning"))
        XCTAssertTrue(source.contains("NSApp.terminate(nil)"))
        XCTAssertTrue(source.contains("guard !shouldSkipSetup else { return }"))

        let move = try XCTUnwrap(source.range(of: "AppMover.moveIfNecessary()"))
        let setup = try XCTUnwrap(source.range(of: "AppController.shared.setup()"))
        XCTAssertLessThan(move.lowerBound, setup.lowerBound)
    }

    func testAccessibilityRequestPromptsAndHasSettingsFallback() throws {
        let controller = try read(
            "app/RemarcPackage/Sources/Features/Onboarding/OnboardingWindowController.swift"
        )
        let content = try read(
            "app/RemarcPackage/Sources/Features/Onboarding/OnboardingContentView.swift"
        )

        XCTAssertTrue(controller.contains("AXIsProcessTrustedWithOptions(options)"))
        XCTAssertTrue(controller.contains("kAXTrustedCheckOptionPrompt"))
        XCTAssertTrue(controller.contains("public func openAccessibilitySettings()"))
        XCTAssertTrue(content.contains("waitingAction: { controller.openAccessibilitySettings() }"))
        XCTAssertTrue(content.contains("Text(L10n.tr(\"Open Settings\"))"))
    }

    func testScreenRecordingUsesSystemRequestAndShipsPurposeString() throws {
        let controller = try read(
            "app/RemarcPackage/Sources/Features/Capture/Permission/ScreenRecordingPermissionController.swift"
        )
        let onboarding = try read(
            "app/RemarcPackage/Sources/Features/Onboarding/OnboardingWindowController.swift"
        )
        let infoPlist = try read("app/Remarc/Info.plist")

        XCTAssertTrue(controller.contains("CGRequestScreenCaptureAccess()"))
        XCTAssertTrue(controller.contains("public func openSystemSettingsPane()"))
        XCTAssertTrue(controller.contains("Button(action: { controller.openSystemSettingsPane() })"))
        XCTAssertTrue(onboarding.contains("permissionController.requestSystemPermission()"))
        XCTAssertTrue(infoPlist.contains("<key>NSScreenCaptureUsageDescription</key>"))
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
