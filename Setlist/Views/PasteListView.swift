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

            HStack {
                TextField("Job name", text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Button("Parse") { model.parseDraft() }
                    .disabled(model.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                Spacer()
            }

            if !model.draftTracks.isEmpty {
                TrackTableView(tracks: $model.draftTracks, detailed: false)
                    .frame(minHeight: 200)
                HStack {
                    Text("\(model.draftTracks.count) tracks")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download \(model.draftTracks.count) tracks") {
                        model.startPasteListJob()
                    }
                    .buttonStyle(.borderedProminent)
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
