import CoreLocalization
import SwiftUI

struct AttachmentStripView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let attachments: [String]
    var commentText: String? = nil
    var isEditable: Bool = true
    var maxThumbnailWidth: CGFloat = 140
    var maxThumbnailHeight: CGFloat = 100
    var onRemove: ((Int) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, path in
                    attachmentThumbnail(path: path, index: index)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, isEditable ? 4 : 0)
        }
    }

    @ViewBuilder
    private func attachmentThumbnail(path: String, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            ScreenshotThumbnailView(imagePath: path, maxWidth: maxThumbnailWidth, maxHeight: maxThumbnailHeight)
                .modifier(ImagePreviewAffordance())
                .contentShape(Rectangle())
                .onTapGesture {
                    ScreenshotPreviewController.shared.show(imagePath: path, commentText: commentText)
                }
                .imageContextMenu(imagePath: path)

            if isEditable {
                Button {
                    onRemove?(index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
    }
}
