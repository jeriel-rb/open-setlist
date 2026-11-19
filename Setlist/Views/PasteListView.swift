import SwiftUI
import SetlistCore

struct PasteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a tracklist")
                .font(.title2.weight(.semibold))
            Text("One song per line. Timestamps, numbering and headers are removed for you. Links are downloaded directly.")
                .foregroundStyle(.secondary)

            TextEditor(text: $model.draftText)
                .font(.body.monospaced())
                .frame(minHeight: 140)
                .overlay(alignment: .topLeading) {
                    if model.draftText.isEmpty {
                        Text("00:00 NewJeans - Right Now (R&B Remix)\n01:30 XG - LEFT RIGHT\n…")
                            .foregroundStyle(.tertiary)
                            .font(.body.monospaced())
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .onChange(of: model.draftText) { _, _ in model.parseDraft() }

            if !model.draftTracks.isEmpty {
                Text("\(model.draftTracks.count) tracks found. Fix any line below before downloading.")
                    .foregroundStyle(.secondary)
                TrackTableView(tracks: $model.draftTracks, detailed: false)
                    .frame(minHeight: 200)
                HStack {
                    Text("Folder name")
                    TextField(AppModel.defaultName("Text"), text: $model.draftName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                    Spacer()
                    Button("Download \(model.draftTracks.count) tracks") {
                        model.startPasteListJob()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isWorking)
                }
            } else {
                Spacer()
            }
        }
        .padding(20)
        .navigationTitle("Text")
    }
}
