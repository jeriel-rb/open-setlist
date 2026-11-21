import SwiftUI
import SetlistCore

struct LinkView: View {
    @Environment(AppModel.self) private var model

    private var status: String {
        if model.isResolvingLinks {
            let found = model.linkTracks.count
            guard found > 0 else { return "Looking up your links…" }
            let named = model.linkTracks.filter { !TrackParser.isURL($0.displayName) }.count
            return "\(found) tracks found so far. Reading their names: \(named) of \(found). You can start the download now."
        }
        switch model.linkTracks.count {
        case 0: return "The songs in your links are listed here."
        case 1: return "1 track found. Fix any line below before downloading."
        default: return "\(model.linkTracks.count) tracks found. Fix any line below before downloading."
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            DraftHeader(title: "Paste links",
                        detail: "YouTube, SoundCloud or Spotify. One link per line. Playlists and albums are opened up into their songs. Spotify songs are found on YouTube, since Spotify serves no audio.")

            PlaceholderTextEditor(text: $model.linkText,
                                  placeholder: "https://open.spotify.com/track/…\nhttps://youtu.be/…\nhttps://soundcloud.com/…")
                .frame(minHeight: 110)
                .onChange(of: model.linkText) { _, _ in model.linkTextChanged() }

            HStack(spacing: 6) {
                if model.isResolvingLinks { ProgressView().controlSize(.small) }
                Text(status)
                    .foregroundStyle(.secondary)
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

            TrackTableView(tracks: $model.linkTracks, detailed: false)
                .frame(minHeight: 160)
            DownloadBar(namePlaceholder: model.linkPlaylistName ?? AppModel.defaultName("Links"), name: $model.linkName,
                        count: model.readyTracks(model.linkTracks, in: .text).count,
                        skipped: model.skippedCount(model.linkTracks, in: .text),
                        // Spotify links come back as song names, which are then searched for.
                        searches: model.linkTracks.contains { !TrackParser.isURL($0.query) },
                        target: $model.linkTarget) {
                model.startLinkJob()
            }
        }
        // Fill the pane from the top, so every screen keeps the same 20 pt margin on all four sides.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .navigationTitle("Link")
    }
}
