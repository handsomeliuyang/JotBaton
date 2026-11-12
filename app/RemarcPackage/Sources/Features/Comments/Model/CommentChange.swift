/// Changes emitted by the document workflow. Integrations decide how to deliver them.
public enum CommentChange: Sendable {
    case commentCreated, commentUpdated, commentDeleted, commentResolved, commentStatusChanged
}
