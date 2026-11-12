import CoreLocalization
import CorePlatform
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    var excludedAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                L10n.tr("Excluded Apps"),
                description: L10n.tr("Remarc won't show the comment tooltip in these apps.")
            )

            List(excludedApps, selection: $excludedSelection) { app in
                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    }
                    Text(app.name)
                        .font(.system(size: 13))
                    Spacer()
                    Text(app.bundleID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.35))
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if excludedApps.isEmpty {
                    VStack(spacing: 4) {
                        Text(L10n.tr("No excluded apps"))
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.4))
                        Text(L10n.tr("Click + to add an application."))
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.3))
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: addExcludedApp) {
                    Image(systemName: "plus")
                }
                .help(L10n.tr("Add application"))

                Button(action: removeSelectedApps) {
                    Image(systemName: "minus")
                }
                .disabled(excludedSelection.isEmpty)
                .help(L10n.tr("Remove selected"))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadExcludedApps() }
    }

    var screenshotFolderURL: URL {
        if settings.screenshotDirectoryPath.isEmpty {
            return remarcAppSupportURL.appendingPathComponent("images", isDirectory: true)
        }
        return URL(fileURLWithPath: settings.screenshotDirectoryPath, isDirectory: true)
    }

    var screenshotFolderDescription: String {
        let path = screenshotFolderURL.path
        let home = NSHomeDirectory()
        if path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    func useDefaultScreenshotFolder() {
        setScreenshotFolder(nil)
    }

    func setScreenshotFolder(_ directory: URL?) {
        do {
            try settings.setScreenshotDirectory(directory)
            screenshotFolderError = nil
        } catch {
            screenshotFolderError = error.localizedDescription
        }
    }

    func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr("Choose")
        panel.message = L10n.tr("Choose a folder for screenshot files")
        panel.directoryURL = screenshotFolderURL

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            self.setScreenshotFolder(url)
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = L10n.tr("Select applications to exclude")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier else { continue }
                if !self.settings.excludedAppBundleIDs.contains(bundleID) {
                    self.settings.excludedAppBundleIDs.append(bundleID)
                }
            }
            self.loadExcludedApps()
        }

        // Present as sheet so it appears above the high-level settings window
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func removeSelectedApps() {
        settings.excludedAppBundleIDs.removeAll { excludedSelection.contains($0) }
        excludedSelection.removeAll()
        loadExcludedApps()
    }

    func loadExcludedApps() {
        excludedApps = settings.excludedAppBundleIDs.map { bundleID in
            let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
            let name = path.map { FileManager.default.displayName(atPath: $0) } ?? bundleID
            let icon = path.map { NSWorkspace.shared.icon(forFile: $0) }
            return ExcludedAppInfo(bundleID: bundleID, name: name, icon: icon)
        }
    }


}
