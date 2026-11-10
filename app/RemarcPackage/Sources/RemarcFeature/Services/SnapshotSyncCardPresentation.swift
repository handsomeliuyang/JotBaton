/// A card has one control: either an available operation or a passive status.
/// Content equality is separate from delivery: an unconfirmed upload must never
/// become a success just because the local and discovered content match.
struct SnapshotSyncCardPresentation: Equatable {
    enum Action: Equatable { case enable, check, apply, publish, choose, recover, retry }

    struct Control: Equatable {
        let symbol: String
        let description: String
        var action: Action? = nil
        var tone: SnapshotSyncPresentation.Tone = .neutral
        var isWorking = false
    }

    let cloud: Control
    let local: Control
    let toolbarSymbol: String
    let showsContentTimes: Bool

    static func make(enabled: Bool, directoryReady: Bool, busy: Bool,
                     transfer: SnapshotCloudTransfer, comparison: SnapshotComparison,
                     publication: SnapshotPublication?, issue: SnapshotSyncIssue?,
                     presentation: SnapshotSyncPresentation, cloudCount: Int) -> Self {
        var cloud: Control
        var local = Control(symbol: "internaldrive", description: L10n.tr("Tasks are stored on this Mac"))
        var toolbar = "icloud"

        if !enabled {
            cloud = Control(symbol: "power", description: L10n.tr("Enable iCloud snapshots"), action: .enable)
            toolbar = "icloud.slash"
        } else if busy {
            cloud = Control(symbol: "icloud", description: presentation.title, isWorking: true)
            local = Control(symbol: "clock", description: L10n.tr("Wait for the current operation to finish"))
        } else if issue != nil && presentation.action != .choose {
            cloud = Control(symbol: "exclamationmark.circle", description: L10n.tr("Show sync issue and recovery options"),
                            action: .recover, tone: presentation.tone)
            toolbar = "exclamationmark.icloud"
        } else if transfer.isActive {
            cloud = Control(symbol: "icloud", description: transfer.title, isWorking: true)
            local = Control(symbol: "clock", description: L10n.tr("Local tasks are kept while iCloud transfers data"))
        } else if transfer == .failed {
            cloud = Control(symbol: "exclamationmark.circle", description: L10n.tr("Show transfer issue and recovery options"),
                            action: .recover, tone: .error)
            toolbar = "exclamationmark.icloud"
        } else if let publication, publication.isPending {
            let canRetry = publication.phase == .savedLocally
            cloud = Control(symbol: canRetry ? "arrow.clockwise" : "clock",
                            description: canRetry ? L10n.tr("Retry uploading the saved snapshot") : L10n.tr("Upload is unconfirmed. Check iCloud again"),
                            action: canRetry ? .retry : .check, tone: .warning)
            local = Control(symbol: "clock", description: L10n.tr("Snapshot saved. Cloud upload is not confirmed"), tone: .warning)
            toolbar = "icloud.and.arrow.up"
        } else if transfer == .waiting {
            cloud = Control(symbol: "clock", description: L10n.tr("Waiting for iCloud. Click to check again"), action: .check, tone: .warning)
            local = Control(symbol: "clock", description: L10n.tr("Local tasks are kept while waiting for iCloud"))
        } else if !directoryReady {
            cloud = Control(symbol: "icloud", description: L10n.tr("Check iCloud Drive access"), action: .check, tone: .warning)
        } else if issue != nil {
            cloud = Control(symbol: "arrow.triangle.branch", description: L10n.tr("Review different copies and choose which data to keep"),
                            action: .choose, tone: .warning)
            local = cloud
            toolbar = "exclamationmark.icloud"
        } else {
            switch comparison {
            case .same:
                cloud = Control(symbol: "checkmark.circle", description: L10n.tr("Matches this Mac. Click to check iCloud again"),
                                action: .check, tone: .success)
                local = Control(symbol: "checkmark.circle", description: L10n.tr("Up to date with iCloud. Click to check again"),
                                action: .check, tone: .success)
                toolbar = "checkmark.icloud"
            case .publish:
                cloud = Control(symbol: "icloud", description: cloudCount == 0 ? L10n.tr("Nothing published yet") : L10n.tr("The cloud copy has no unapplied changes"))
                local = Control(symbol: "arrow.up.circle", description: L10n.tr("Publish this Mac's changes to iCloud"), action: .publish)
                toolbar = "icloud.and.arrow.up"
            case .receive:
                cloud = Control(symbol: "arrow.down.circle", description: L10n.tr("Review and apply cloud data to this Mac"), action: .apply)
                local = Control(symbol: "clock", description: L10n.tr("Cloud changes have not been applied to this Mac"))
                toolbar = "icloud.and.arrow.down"
            case .choose:
                cloud = Control(symbol: "arrow.triangle.branch", description: L10n.tr("Review different copies and choose which data to keep"),
                                action: .choose, tone: .warning)
                local = cloud
                toolbar = "exclamationmark.icloud"
            }
        }
        return Self(cloud: cloud, local: local, toolbarSymbol: toolbar,
                    showsContentTimes: enabled && directoryReady && comparison != .same)
    }
}
