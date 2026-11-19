import SwiftUI
import SetlistCore

/// The Help window: what each screen does and what the marks and tags in a job mean.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Three ways to start") {
                    row(icon: "text.alignleft", title: "Text",
                        text: "Paste or type song names, one per line, like “XG - LEFT RIGHT”. Timestamps and numbering are removed for you. Each song is searched for on YouTube, then SoundCloud.")
                    row(icon: "link", title: "Link",
                        text: "Paste YouTube, SoundCloud or Spotify links, one per line. Playlists and albums are opened up into their songs. Spotify has no audio to download, so its songs are found on YouTube by name.")
                    row(icon: "waveform.badge.magnifyingglass", title: "YouTube Set",
                        text: "Paste the link of one DJ set or mix. If its description or comments list the songs, that list is used. If not, the mix is downloaded and Shazam listens to it, naming the songs one by one.")
                }

                section("The Match column") {
                    Text("How sure the app is that the row names the right song.")
                        .foregroundStyle(.secondary)
                    ForEach(Confidence.allCases, id: \.self) { confidence in
                        legend(text: confidence.explanation) { ConfidenceBadge(confidence: confidence) }
                    }
                }

                section("The mark at the start of each row") {
                    ForEach(TrackStatus.allCases, id: \.self) { status in
                        legend(text: status.explanation) { StatusIcon(status: status).frame(width: 20) }
                    }
                }

                section("BPM and Key") {
                    Text("Worked out on your Mac from the downloaded file, and saved in the file's tags so DJ software can read them.")
                    Text("**BPM** is the tempo. It is occasionally read at double or half the real value (198 for a song that is really 99).")
                    Text("**Key** is shown as a Camelot code such as 8A. Two songs usually mix well when the number is the same or one apart and the letter matches: 8A goes with 7A, 8A and 9A. A is minor, B is major. Hover over a key to see its musical name.")
                }

                section("Source") {
                    Text("The page the audio was downloaded from. Click it to open that page and check it is the version you wanted.")
                }

                section("While a job runs, and after") {
                    Text("**Stop** ends the job; what is already downloaded stays.")
                    Text("**Resume** continues a mix from the point Shazam had reached. Nothing is downloaded twice.")
                    Text("**Retry** tries the failed and cancelled songs again.")
                    Text("**Rename Files** changes how the files in that one folder are named. The naming for new downloads is in Settings.")
                    Text("Click a job's title to rename it; its folder is renamed too. Click a column heading to sort. Double-click a downloaded song to play it.")
                }

                section("When something does not work") {
                    Text("**Many songs fail at once**: open Settings and press Update next to yt-dlp. YouTube changes often and the downloader has to keep up.")
                    Text("**“Shazam is not available”**: this copy of the app was not built with Shazam access. Mixes that have a posted tracklist still work.")
                    Text("**A wrong song was downloaded**: check its Source, then add the artist or “official audio” to the line in the Text tab and download it again.")
                    Text("**A line has an orange warning**: hover over it to see why. Lines with a warning are skipped.")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 640)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }

    private func row(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(text: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            mark().frame(width: 124, alignment: .leading)
            Text(text)
        }
    }
}

extension Confidence: @retroactive CaseIterable {
    public static var allCases: [Confidence] { [.high, .medium, .fromText, .low] }

    /// What the tag means, in a sentence.
    var explanation: String {
        switch self {
        case .high:
            "You typed or pasted it yourself, or Shazam recognised this exact version, remix included."
        case .medium:
            "Shazam recognised the song, but mixes often play a remix or edit of it. The original recording is what gets downloaded."
        case .fromText:
            "Taken from the tracklist posted in the video's description or comments, not checked by listening."
        case .low:
            "Nothing was recognised here. The row is skipped unless you type a song into it."
        }
    }
}

extension TrackStatus: @retroactive CaseIterable {
    public static var allCases: [TrackStatus] { [.pending, .searching, .downloading, .analyzing, .done, .failed, .skipped, .cancelled] }

    var explanation: String {
        switch self {
        case .pending: "Waiting its turn. Two songs download at a time."
        case .searching: "Looking for the song."
        case .downloading: "Downloading and converting to MP3."
        case .analyzing: "Working out BPM and key."
        case .done: "Downloaded and in the folder."
        case .failed: "Could not be downloaded. The reason is shown under the song; Retry tries again."
        case .skipped: "Left out on purpose, because nothing was recognised for it."
        case .cancelled: "Not downloaded because the job was stopped or the app quit. Retry or Resume picks it up."
        }
    }
}
