import SwiftUI

/// The same optional title control is used in selection, screenshot and note composers.
struct TaskTitleField: View {
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @Binding var text: String
    let automaticTitle: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("标题（可选）")
                .foregroundStyle(.secondary)
                .fixedSize()
            TextField(
                automaticTitle == CommentTitlePolicy.untitled ? "输入任务名称，留空自动取名" : automaticTitle,
                text: $text
            )
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .focused($isFocused)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused
                        ? Color.remarcPrimary(for: colorScheme).opacity(0.55)
                        : Color.primary.opacity(0.08))
                    .frame(height: 1)
            }
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .onSubmit(onSubmit)
            .help("留空时自动使用引用文字、正文或文件名")
            .accessibilityLabel("任务标题（可选）")
            .accessibilityIdentifier("remarc.taskTitle")
        }
        .font(.system(size: 13))
    }
}
