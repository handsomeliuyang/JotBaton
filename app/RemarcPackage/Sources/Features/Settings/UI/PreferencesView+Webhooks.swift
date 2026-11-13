import CoreLocalization
import CoreTheme
import CoreUI
import FeatureIntegrations
import FeatureSettings
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    // MARK: - Webhooks Tab

    var webhooksSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader(
                    L10n.tr("Webhooks"),
                    description: L10n.tr("Send comment events to any service as HTTP POST requests.")
                ) {
                    addWebhookButton
                }

                CalloutView(.info, L10n.tr("Works with Zapier, Make, n8n, IFTTT, Slack incoming webhooks, or any endpoint that accepts JSON."))

                if settings.webhooks.isEmpty {
                    Text(L10n.tr("No webhooks yet. Add one to send comment events - created, resolved, deleted - to any URL, or send individual cards manually from their paperplane action."))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(settings.webhooks) { webhook in
                            webhookRow(webhook)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $webhookEditorState) { state in
            WebhookEditorSheet(state: state) { saved in
                if let index = settings.webhooks.firstIndex(where: { $0.id == saved.id }) {
                    settings.webhooks[index] = saved
                } else {
                    settings.webhooks.append(saved)
                }
            }
        }
        .confirmationDialog(
            L10n.tr("Delete webhook \"\(webhookPendingDelete?.name ?? "")\"?"),
            isPresented: Binding(
                get: { webhookPendingDelete != nil },
                set: { if !$0 { webhookPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Delete"), role: .destructive) {
                if let pending = webhookPendingDelete {
                    settings.webhooks.removeAll { $0.id == pending.id }
                }
                webhookPendingDelete = nil
            }
            Button(L10n.tr("Cancel"), role: .cancel) {
                webhookPendingDelete = nil
            }
        }
    }

    var addWebhookButton: some View {
        textButton(L10n.tr("Add Webhook")) {
            webhookEditorState = WebhookEditorState(webhook: Webhook(), isNew: true)
        }
        .help(L10n.tr("Add a new webhook endpoint"))
    }

    func webhookRow(_ webhook: Webhook) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(webhook.name)
                        .font(.system(size: 13, weight: .medium))
                    webhookStatusIcon(webhook)
                }
                Text(webhook.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if testingWebhookIDs.contains(webhook.id) {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.tr("Sending test event"))
            } else {
                CardActionButton(icon: "paperplane", tooltip: L10n.tr("Send test event"), tint: Color.remarcPrimary(for: colorScheme)) {
                    sendTestWebhook(webhook)
                }
            }
            CardActionButton(icon: "pencil", tooltip: L10n.tr("Edit"), tint: Color.remarcPrimary(for: colorScheme)) {
                webhookEditorState = WebhookEditorState(webhook: webhook, isNew: false)
            }
            CardActionButton(icon: "trash", tooltip: L10n.tr("Delete"), tint: Color.remarcError(for: colorScheme)) {
                webhookPendingDelete = webhook
            }
            Toggle(L10n.tr("Enable \(webhook.name)"), isOn: webhookEnabledBinding(webhook))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(webhook.isEnabled ? L10n.tr("Disable this webhook") : L10n.tr("Enable this webhook"))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .opacity(webhook.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    func webhookStatusIcon(_ webhook: Webhook) -> some View {
        switch webhookService.lastDeliveries[webhook.id] {
        case .success(let date):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.remarcSuccess(for: colorScheme))
                .help(L10n.tr("Delivered at \(date.interfaceFormatted(date: .omitted, time: .shortened))"))
        case .failure(let date, let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.remarcWarning(for: colorScheme))
                .help(L10n.tr("Failed at \(date.interfaceFormatted(date: .omitted, time: .shortened)): \(L10n.lookup(message))"))
        case nil:
            EmptyView()
        }
    }

    func webhookEnabledBinding(_ webhook: Webhook) -> Binding<Bool> {
        Binding(
            get: { settings.webhooks.first(where: { $0.id == webhook.id })?.isEnabled ?? false },
            set: { newValue in
                if let index = settings.webhooks.firstIndex(where: { $0.id == webhook.id }) {
                    settings.webhooks[index].isEnabled = newValue
                }
            }
        )
    }

    // Feedback comes from the row's status icon - the toast overlay lives in the
    // menu bar popover, which is closed whenever Settings is open.
    func sendTestWebhook(_ webhook: Webhook) {
        testingWebhookIDs.insert(webhook.id)
        Task { @MainActor in
            await webhookService.sendTest(webhook)
            testingWebhookIDs.remove(webhook.id)
        }
    }

}
