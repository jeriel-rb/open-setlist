import SwiftUI

/// A multi-line monospaced editor with placeholder text that sits exactly where typing starts.
struct PlaceholderTextEditor: View {
    @Binding var text: String
    let placeholder: String

    /// Space between the border and the text.
    private static let inset: CGFloat = 8
    /// `TextEditor` on macOS indents its text by the text container's line fragment padding and
    /// adds no vertical inset of its own, so the placeholder needs this much extra on the leading edge only.
    private static let lineFragmentPadding: CGFloat = 5

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(.vertical, Self.inset)
            .padding(.horizontal, Self.inset - Self.lineFragmentPadding)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(Self.inset)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}

/// Heading and explanation at the top of each "New" screen.
struct DraftHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }
}

/// Folder name field and the Download button under a draft's track table.
struct DownloadBar: View {
    @Environment(AppModel.self) private var model
    let namePlaceholder: String
    @Binding var name: String
    /// Tracks the button will download.
    let count: Int
    let action: () -> Void

    var body: some View {
        HStack {
            Text("Folder name")
            TextField(namePlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            Spacer()
            Button(count == 1 ? "Download 1 track" : "Download \(count) tracks", action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isWorking || count == 0)
                .help(model.isWorking ? "Another download is still running." : "")
        }
    }
}
