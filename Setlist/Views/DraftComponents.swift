import SwiftUI
import SetlistCore

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
    /// Rows that will be left out because of a problem.
    var skipped = 0
    /// True when at least one track is a song name that has to be searched for, not a direct link.
    var searches = true
    /// The existing job to add to, on screens that offer it; nil inside means a new folder.
    var target: Binding<UUID?>?
    let action: () -> Void

    /// The picked job, as long as it still exists.
    private var chosen: UUID? {
        guard let id = target?.wrappedValue, model.addableJobs.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// A job as a line of the "Save to" menu. The menu's button is as wide as its longest line and does
    /// not shrink, so a long name (a playlist's title names its folder) is cut short here.
    private func menuTitle(_ job: Job) -> String {
        let name = job.name.count > 40 ? job.name.prefix(40).trimmingCharacters(in: .whitespaces) + "…" : job.name
        return "\(name) (\(job.tracks.count == 1 ? "1 song" : "\(job.tracks.count) songs"))"
    }

    private var buttonTitle: String {
        let verb = searches ? "Find & Download" : "Download"
        switch count {
        case 0: return "\(verb) Tracks"
        case 1: return "\(verb) 1 Track"
        default: return "\(verb) \(count) Tracks"
        }
    }

    var body: some View {
        HStack {
            if let target, !model.addableJobs.isEmpty {
                Picker("Save to", selection: Binding(get: { chosen }, set: { target.wrappedValue = $0 })) {
                    Text("New folder").tag(UUID?.none)
                    Divider()
                    ForEach(model.addableJobs) { job in
                        Text(menuTitle(job)).tag(UUID?.some(job.id))
                    }
                }
                .fixedSize()
                .help("Start a new folder, or add these songs to one you already have. Songs it already has are not downloaded again.")
            }
            if chosen == nil {
                Text("Folder name")
                TextField(namePlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            }
            Spacer()
            if skipped > 0 {
                Label(skipped == 1 ? "1 line will be skipped" : "\(skipped) lines will be skipped", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .help("Lines marked with a warning in the list are not downloaded. Hover over the mark to see why.")
            }
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isWorking || count == 0)
                .help(model.isWorking ? "Another download is still running."
                      : searches ? "Each song is searched for on YouTube and SoundCloud. The result that best matches the line, remix or edit included, is downloaded as an MP3." : "")
        }
    }
}
