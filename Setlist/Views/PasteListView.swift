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
                .frame(minHeight: 110)
                .onChange(of: model.draftText) { _, _ in model.parseDraft() }

            Text(model.draftTracks.isEmpty
                 ? "The songs found in your text are listed here."
                 : "\(model.draftTracks.count == 1 ? "1 track" : "\(model.draftTracks.count) tracks") found. Fix any line below before downloading.")
                .foregroundStyle(.secondary)
            TrackTableView(tracks: $model.draftTracks, detailed: false)
                .frame(minHeight: 160)
            DownloadBar(namePlaceholder: AppModel.defaultName("Text"), name: $model.draftName,
                        count: model.readyTracks(model.draftTracks, in: .text).count,
                        skipped: model.skippedCount(model.draftTracks, in: .text),
                        searches: model.draftTracks.isEmpty || model.draftTracks.contains { !TrackParser.isURL($0.query) },
                        target: $model.draftTarget) {
                model.startPasteListJob()
            }
        }
        // Fill the pane from the top, so every screen keeps the same 20 pt margin on all four sides.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .navigationTitle("Text")
    }
}
