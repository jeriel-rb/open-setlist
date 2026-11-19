import SwiftUI
import SetlistCore

/// Paste a mix link, get its tracklist (posted, or identified with ShazamKit), fix it, download it.
struct YouTubeSetView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            DraftHeader(title: "Identify a mix",
                        detail: "Paste the link of a DJ set or mix. A tracklist posted in the description or comments is used when there is one. Otherwise the mix is downloaded and Shazam names its songs one by one; each appears in History and downloads as soon as it is found.")

            HStack {
                TextField("https://www.youtube.com/watch?v=…", text: $model.setURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isIdentifying)
                    .onSubmit { model.startIdentify() }
                if model.isIdentifying {
                    Button(role: .destructive) {
                        model.cancelIdentify()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button("Identify") { model.startIdentify() }
                        .disabled(model.setURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let stage = model.setStage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(stage + "…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.setError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if !model.setTracks.isEmpty {
                if let source = model.setSource {
                    Label(Self.describe(source), systemImage: source == .shazam ? "shazam.logo" : "text.quote")
                        .foregroundStyle(.secondary)
                }
                TrackTableView(tracks: $model.setTracks, detailed: true)
                    .frame(minHeight: 200)
                DownloadBar(namePlaceholder: AppModel.defaultName("Set"), name: $model.setName,
                            count: model.setDownloadableCount) {
                    model.startYouTubeSetJob()
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .navigationTitle("YouTube Set")
    }

    private static func describe(_ source: IdentifyResult.Source) -> String {
        switch source {
        case .description: "Tracklist found in the description. Fix any line before downloading."
        case .comments: "Tracklist found in a comment. Fix any line before downloading."
        case .shazam: "Identified with Shazam."
        }
    }
}
