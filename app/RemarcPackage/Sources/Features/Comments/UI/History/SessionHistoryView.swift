import CoreLocalization
import CoreTheme
import CoreUI
import FeatureComments
import SwiftUI

struct SessionHistoryView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var persistence = AppServices.shared.comments
    @Binding var showingHistory: Bool
    @Binding var searchText: String
    @Binding var sortNewestFirst: Bool

    private var sessions: [Session] {
        persistence.deletedSessions.filter { session in
            searchText.isEmpty || session.name.localizedStandardContains(searchText)
                || session.id.uuidString.localizedStandardContains(searchText)
        }.sorted { lhs, rhs in
            let left = lhs.deletedAt ?? lhs.autoDismissedAt ?? lhs.createdAt
            let right = rhs.deletedAt ?? rhs.autoDismissedAt ?? rhs.createdAt
            return sortNewestFirst ? left > right : left < right
        }
    }

    var body: some View {
        if sessions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: searchText.isEmpty ? "clock" : "magnifyingglass")
                    .font(.system(size: 32)).foregroundStyle(.primary.opacity(0.25))
                Text(searchText.isEmpty ? L10n.tr("No sessions in History") : L10n.tr("No results"))
                    .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sessions) { session in
                        SessionHistoryCard(session: session) {
                            if persistence.restoreSession(session.id) {
                                withAnimation(.easeInOut(duration: 0.15)) { showingHistory = false }
                                ToastManager.shared.show(L10n.tr("Session restored"))
                            } else {
                                ToastManager.shared.show(L10n.tr("Could not restore the session. Try again."))
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .background(ScrollerHider())
        }
    }
}

private struct SessionHistoryCard: View {
    let session: Session
    let onRestore: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SessionOriginBadge(origin: session.origin)
                    Text(session.name).font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                let date = session.deletedAt ?? session.autoDismissedAt ?? session.createdAt
                Text(L10n.tr("Moved to History \(date.interfaceFormatted(date: .abbreviated, time: .shortened))"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onRestore) {
                Label(L10n.tr("Restore"), systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 5)
                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                    .background(Color.remarcPrimary(for: colorScheme).opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Restore session"))
            .accessibilityIdentifier("history.restoreSession.\(session.id)")
        }
        .padding(12)
        .modifier(CardSurfaceModifier(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}
