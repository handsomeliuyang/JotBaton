import CoreLocalization
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    #if DEBUG
    var experimentalSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        L10n.tr("HyperFrames Context"),
                        leadingIcon: "HyperFramesLogo",
                        description: L10n.tr("Attach HyperFrames composition context (beat, active tweens, source-line ranges) to web-element, region, and quick-note comments captured on HF compositions. Experimental — requires a `window.__remarcHFContext` bridge in the composition.")
                    )

                    toggleRow(L10n.tr("Capture HyperFrames context"), isOn: $settings.webContextHyperframesEnabled)

                    if settings.webContextHyperframesEnabled {
                        Text(L10n.tr("When grabbing an element (or region) on a page that exposes `window.__remarcHFContext`, Remarc captures the current paused timeline moment, the active beat, and the top-3 active tweens with their `timeline.js` source-line ranges. Use Alt+Shift+N for a quick note tied only to the timeline moment (no DOM target)."))
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        L10n.tr("Reset"),
                        description: L10n.tr("Experimental reset actions. These are destructive.")
                    )

                    HStack(spacing: 12) {
                        Button(L10n.tr("Reset Data")) {
                            showResetDataConfirm = true
                        }
                        .foregroundStyle(.red)
                        .alert(L10n.tr("Reset Data"), isPresented: $showResetDataConfirm) {
                            Button(L10n.tr("Cancel"), role: .cancel) {}
                            Button(L10n.tr("Reset"), role: .destructive) {
                                resetDataForTesting()
                            }
                        } message: {
                            Text(L10n.tr("This will delete all comments and sessions. Restart the app to complete the reset."))
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    func resetDataForTesting() {
        AppServices.shared.comments.removeDocumentForTesting()
    }
    #endif

}
