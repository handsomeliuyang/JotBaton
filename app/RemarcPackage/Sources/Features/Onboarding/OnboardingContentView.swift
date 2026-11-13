import CoreLocalization
import CoreTheme
import CoreUI
import SwiftUI
import AppKit

package struct OnboardingContentView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @EnvironmentObject var controller: OnboardingWindowController
    @Environment(\.colorScheme) var colorScheme
    @State private var isContinueHovered = false
    package var body: some View {
        VStack(spacing: 0) {
            Spacer()

            appIcon
                .padding(.bottom, 16)

            welcomeText
                .padding(.bottom, 28)

            permissionRows
                .padding(.horizontal, 40)

            continueButton
                .padding(.top, 24)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(
            width: OnboardingMetrics.onboardingWindowWidth,
            height: OnboardingMetrics.onboardingWindowHeight
        )
        .background(.regularMaterial)
    }

    // MARK: - App Icon

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 80, height: 80)
        } else {
            Image(systemName: "text.bubble")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
                .frame(width: 80, height: 80)
        }
    }

    // MARK: - Welcome Text

    private var welcomeText: some View {
        VStack(spacing: 8) {
            Text(L10n.tr("Welcome to JotBaton!"))
                .font(.system(size: 24, weight: .bold))

            Text(L10n.tr("A few permissions are needed to get started."))
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Permission Rows

    private var permissionRows: some View {
        VStack(spacing: 10) {
            permissionRow(
                icon: "hand.raised.fill",
                title: L10n.tr("Accessibility"),
                description: L10n.tr("JotBaton reads your selected text so it can attach comments to it."),
                state: controller.accessibilityState,
                action: { controller.requestAccessibility() },
                waitingAction: { controller.openAccessibilitySettings() }
            )

            permissionRow(
                icon: "rectangle.dashed.badge.record",
                title: L10n.tr("Screen Recording"),
                description: L10n.tr("Used to capture screenshots of selected regions alongside your comments."),
                state: controller.screenRecordingState,
                action: { controller.requestScreenRecording() },
                waitingAction: { controller.openScreenRecordingSettings() }
            )

        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        state: PermissionRowState,
        action: @escaping () -> Void,
        waitingAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color.remarcPrimary(for: colorScheme))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            permissionStatusButton(state: state, action: action, waitingAction: waitingAction)
                .frame(width: 130)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: colorScheme == .dark ? 1.0 : 0.0).opacity(0.015))
        )
    }

    @ViewBuilder
    private func permissionStatusButton(
        state: PermissionRowState,
        action: @escaping () -> Void,
        waitingAction: (() -> Void)?
    ) -> some View {
        switch state {
        case .needsPermission:
            AllowButton(colorScheme: colorScheme, action: action)

        case .waitingForGrant:
            if let waitingAction {
                Button(action: waitingAction) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.55)
                        Text(L10n.tr("Open Settings"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundColor(Color.remarcPrimary(for: colorScheme))
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.55)
                    Text(L10n.tr("Waiting..."))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

        case .granted:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                Text(L10n.tr("Enabled"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(Color.remarcSuccess(for: colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.remarcSuccess(for: colorScheme).opacity(0.15))
            )
        }
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        let enabled = controller.allPermissionsGranted

        return Button(action: { controller.continueFromOnboarding() }) {
            Text(L10n.tr("Continue"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(enabled ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(
                            enabled
                                ? AnyShapeStyle(Color.remarcBrandGradient(for: colorScheme))
                                : AnyShapeStyle(Color.primary.opacity(0.08))
                        )
                )
                .shadow(
                    color: enabled
                        ? Color.remarcPrimary(for: colorScheme).opacity(isContinueHovered ? 0.45 : 0.25)
                        : .clear,
                    radius: isContinueHovered ? 8 : 5,
                    y: 2
                )
                .scaleEffect(enabled && isContinueHovered ? 1.02 : 1.0)
                .opacity(enabled ? (isContinueHovered ? 1.0 : 0.88) : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isContinueHovered = hovering
            }
        }
    }
}

// MARK: - Allow Button

private struct AllowButton: View {
    @ObservedObject private var localization = LocalizationManager.shared
    package let colorScheme: ColorScheme
    package var title: String = L10n.tr("Allow")
    package let action: () -> Void
    @State private var isHovered = false

    package var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.remarcPrimary(for: colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.remarcPrimary(for: colorScheme).opacity(isHovered ? 0.25 : 0.15))
                )
                .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
