import SwiftUI
import SetlistCore

/// Editable list of tracks before a download starts.
struct TrackTableView: View {
    @Binding var tracks: [Track]
    /// Shows the timestamp and match-confidence columns (YouTube Set).
    var detailed: Bool

    @State private var selection = Set<Track.ID>()

    var body: some View {
        VStack(spacing: 6) {
            if detailed {
                Table($tracks, selection: $selection) {
                    indexColumn
                    TableColumn("Time") { $track in
                        Text(track.start.map(JobStore.timestamp) ?? "")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(64)
                    queryColumn
                    TableColumn("Match") { $track in
                        ConfidenceBadge(confidence: track.confidence, note: track.note)
                    }
                    .width(130)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                Table($tracks, selection: $selection) {
                    indexColumn
                    queryColumn
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }

            HStack {
                ControlGroup {
                    Button {
                        let next = (tracks.map(\.index).max() ?? 0) + 1
                        tracks.append(Track(index: next, query: ""))
                    } label: {
                        Image(systemName: "plus").frame(width: 14, height: 14)
                    }
                    .help("Add a row")
                    Button {
                        tracks.removeAll { selection.contains($0.id) }
                        selection.removeAll()
                        for i in tracks.indices { tracks[i].index = i + 1 }
                    } label: {
                        Image(systemName: "minus").frame(width: 14, height: 14)
                    }
                    .disabled(selection.isEmpty)
                    .help("Remove selected rows")
                }
                .fixedSize()
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var indexColumn: TableColumn<Binding<Track>, Never, Text, Text> {
        TableColumn("#") { (track: Binding<Track>) in
            Text(String(format: "%02d", track.wrappedValue.index))
        }
        .width(32)
    }

    private var queryColumn: TableColumn<Binding<Track>, Never, QueryCell, Text> {
        TableColumn("Artist - Title") { (track: Binding<Track>) in
            QueryCell(track: track)
        }
    }
}

private struct QueryCell: View {
    @Binding var track: Track

    var body: some View {
        TextField("Artist - Title", text: $track.query)
            .textFieldStyle(.plain)
            .onChange(of: track.query) { _, new in
                if track.confidence == .low, !new.isEmpty { track.confidence = .high }
            }
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence
    var note: String?

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .help(note ?? label)
    }

    private var label: String {
        switch confidence {
        case .high: "High"
        case .medium: "Original only"
        case .low: "Not found"
        case .fromText: "Posted tracklist"
        }
    }

    private var color: Color {
        switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .gray
        case .fromText: .blue
        }
    }
}
