import SwiftUI
import SetlistCore

struct LinkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            DraftHeader(title: "Paste links",
                        detail: "YouTube, SoundCloud or Spotify. One link per line. Playlists and Spotify albums are expanded. Spotify songs are matched on YouTube, since Spotify serves no audio.")

            PlaceholderTextEditor(text: $model.linkText,
                                  placeholder: "https://open.spotify.com/track/…\nhttps://youtu.be/…\nhttps://soundcloud.com/…")
                .frame(minHeight: 120)

            HStack {
                Button {
                    Task { await model.resolveLinks() }
                } label: {
                    if model.isResolvingLinks {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking links…") }
                    } else {
                        Text("Check links")
                    }
                }
                .disabled(model.isResolvingLinks || model.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // Once the songs are listed, ⌘↩ belongs to Download.
                .keyboardShortcut(model.linkTracks.isEmpty ? KeyboardShortcut(.return, modifiers: .command) : nil)
                Text("Looks up each link and lists the songs it contains.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }

            if !model.linkFailures.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.linkFailures, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }

            if !model.linkTracks.isEmpty {
                TrackTableView(tracks: $model.linkTracks, detailed: false)
                    .frame(minHeight: 200)
                DownloadBar(namePlaceholder: AppModel.defaultName("Links"), name: $model.linkName,
                            count: model.linkTracks.count) {
                    model.startLinkJob()
                }
            }
        }
        // Fill the pane from the top, so every screen keeps the same 20 pt margin on all four sides.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .navigationTitle("Link")
    }
}
