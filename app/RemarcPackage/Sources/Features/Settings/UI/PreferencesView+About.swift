import CoreLocalization
import CorePlatform
import FeatureSettings
import FeatureUpdates
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    var aboutSection: some View {
        VStack(spacing: 16) {
            Spacer()

            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text(AppIdentity.current.displayName)
                .font(.system(size: 24, weight: .semibold))

            Text(L10n.tr("Contextual comments on any text selection"))
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.6))

            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                Text(L10n.tr("v\(version) (\(build))"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.35))
            }

            Text(L10n.tr("\(AppServices.shared.comments.appState.totalCommentsCreated) remarks created"))
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.35))

            Button(L10n.tr("Check for Updates\u{2026}")) {
                UpdateManager.shared.checkForUpdates()
            }
            .disabled(!updateManager.canCheckForUpdates || updateManager.isChecking)

            if !updateManager.status.isEmpty {
                Text(updateManager.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if updateManager.isUpdating {
                if let progress = updateManager.progress {
                    ProgressView(value: progress).frame(width: 220)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if updateManager.availableVersion != nil {
                Button(L10n.tr("Upgrade and Restart")) { UpdateManager.shared.installUpdate() }
                    .disabled(updateManager.isChecking)
            }

            HStack(spacing: 16) {
                Link(L10n.tr("Website"), destination: URL(string: "https://remarc.app")!)
                Link(L10n.tr("Documentation"), destination: URL(string: "https://docs.remarc.app")!)
                Link(L10n.tr("GitHub"), destination: URL(string: "https://github.com/handsomeliuyang/Remarc")!)
            }
            .font(.system(size: 12))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


}
