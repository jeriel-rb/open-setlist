import SwiftUI
import SetlistCore

struct PasteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            DraftHeader(title: "Paste a tracklist",
                        detail: "One song per line. Timestamps, numbering and headers are removed for you. Links are downloaded directly.")

            PlaceholderTextEditor(text: $model.draftText,
                                  placeholder: "00:00 NewJeans - Right Now (R&B Remix)\n01:30 XG - LEFT RIGHT\n…")
                .frame(minHeight: 140)
                .onChange(of: model.draftText) { _, _ in model.parseDraft() }

            if !model.draftTracks.isEmpty {
                Text("\(model.draftTracks.count == 1 ? "1 track" : "\(model.draftTracks.count) tracks") found. Fix any line below before downloading.")
                    .foregroundStyle(.secondary)
                TrackTableView(tracks: $model.draftTracks, detailed: false)
                    .frame(minHeight: 200)
                DownloadBar(namePlaceholder: AppModel.defaultName("Text"), name: $model.draftName,
                            count: model.draftTracks.count) {
                    model.startPasteListJob()
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .navigationTitle("Text")
    }
}
