import CoreLocalization
import CoreUI
import FeatureComments
import SwiftUI

struct CommentHistoryView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @Binding var showingHistory: Bool
    @Binding var restoredCommentID: UUID?
    @Binding var searchText: String
    @Binding var sortNewestFirst: Bool
    @ObservedObject private var persistence = AppServices.shared.comments
    @Environment(\.colorScheme) private var colorScheme

    private var searchTerms: [String] { CommentListQuery.searchTerms(from: searchText) }

    private var deletedComments: [Comment] {
        let terms = searchTerms
        let sessionNames = Dictionary(uniqueKeysWithValues: persistence.appState.sessions.map { ($0.id, $0.name) })
        return persistence.deletedComments.filter {
            CommentListQuery.matches($0, terms: terms, sessionName: sessionNames[$0.sessionID])
        }.sorted {
            if sortNewestFirst {
                return ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast)
            } else {
                return ($0.deletedAt ?? .distantPast) < ($1.deletedAt ?? .distantPast)
            }
        }
    }

    var body: some View {
        if deletedComments.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(deletedComments) { comment in
                        HistoryCardView(comment: comment, searchTerms: searchTerms, onRestore: {
                            restoreComment(comment)
                        }, onPermanentDelete: {
                            permanentlyDelete(comment)
                        })
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .background(ScrollerHider())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchTerms.isEmpty ? "clock" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.primary.opacity(0.25))

            Text(searchTerms.isEmpty ? L10n.tr("No comments in History") : L10n.tr("No results"))
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func permanentlyDelete(_ comment: Comment) {
        persistence.permanentlyDeleteComment(comment.id)
        ToastManager.shared.show(L10n.tr("Permanently deleted"))
    }

    private func restoreComment(_ comment: Comment) {
        if let sessionID = persistence.appState.activeSessionID {
            let commentID = comment.id
            persistence.restoreComment(commentID, to: sessionID)
            restoredCommentID = commentID
            withAnimation(.easeInOut(duration: 0.15)) { showingHistory = false }
            // Clear highlight after 1.2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.5)) { restoredCommentID = nil }
            }
            ToastManager.shared.show(L10n.tr("Comment restored"))
        }
    }
}
