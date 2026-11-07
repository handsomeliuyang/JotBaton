import SwiftUI

/// The same optional title control is used in selection, screenshot and note composers.
struct TaskTitleField: View {
    @Binding var text: String
    let automaticTitle: String
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("标题（可选）")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(
                automaticTitle == CommentTitlePolicy.untitled ? "输入任务名称，留空自动取名" : automaticTitle,
                text: $text
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .onSubmit(onSubmit)
            .help("留空时自动使用引用文字、正文或文件名")
            .accessibilityLabel("任务标题（可选）")
            .accessibilityIdentifier("remarc.taskTitle")
        }
    }
}
