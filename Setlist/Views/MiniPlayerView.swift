import SwiftUI
import SetlistCore

/// The bar along the bottom of the window that previews a downloaded song.
struct MiniPlayerView: View {
    @Environment(Player.self) private var player
    /// Non-nil while the scrubber is being dragged, so the playhead does not fight the drag.
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            // No Space shortcut: a bare-key shortcut would also fire while typing in a text field.
            .help(player.isPlaying ? "Pause" : "Play")

            Text(player.title ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: 280, alignment: .leading)

            Text(JobStore.timestamp(scrubbing ?? player.currentTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { scrubbing ?? player.currentTime }, set: { scrubbing = $0 }),
                in: 0...max(player.duration, 1)
            ) { editing in
                if !editing, let target = scrubbing {
                    player.seek(to: target)
                    scrubbing = nil
                }
            }
            .controlSize(.small)
            Text(JobStore.timestamp(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                player.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Stop and hide the player")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
