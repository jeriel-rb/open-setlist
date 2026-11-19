import SwiftUI
import SetlistCore

struct LinkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste links")
                .font(.title2.weight(.semibold))
            Text("YouTube, SoundCloud or Spotify. One link per line. Playlists and Spotify albums are expanded. Spotify songs are matched on YouTube, since Spotify serves no audio.")
                .foregroundStyle(.secondary)

            TextEditor(text: $model.linkText)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if model.linkText.isEmpty {
                        Text("https://open.spotify.com/track/…\nhttps://youtu.be/…\nhttps://soundcloud.com/…")
                            .foregroundStyle(.tertiary)
                            .font(.body.monospaced())
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))

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
                .keyboardShortcut(.return, modifiers: .command)
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
                HStack {
                    Text("Folder name")
                    TextField(AppModel.defaultName("Links"), text: $model.linkName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                    Spacer()
                    Button("Download \(model.linkTracks.count) tracks") {
                        model.startLinkJob()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                }
            } else {
                Spacer()
            }
        }
        .padding(20)
        .navigationTitle("Link")
    }
}
