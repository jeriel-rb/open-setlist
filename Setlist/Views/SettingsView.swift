import SwiftUI
import SetlistCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Output") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.outputRoot.tildePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { model.chooseOutputFolder() }
                            .disabled(!model.canChangeOutputFolder)
                            .help(model.canChangeOutputFolder ? "" : "Wait for the running download to finish.")
                    }
                }
                Picker("Audio quality", selection: $model.audioQuality) {
                    Text("Best available").tag("0")
                    Text("192 kbps").tag("192K")
                    Text("128 kbps").tag("128K")
                }
                Toggle(isOn: $model.keepOriginalMix) {
                    Text("Keep the full mix after identifying it")
                    Text("YouTube Set only. The whole mix is downloaded so Shazam can listen to it, then deleted. Turn this on to keep it in the job folder as one long file, “original mix.wav”.")
                }
            }
            FileNameSettings(format: $model.fileNameFormat, title: "File names",
                             note: "Used for downloads you start from now on. To change files you already have, open the job and choose Rename Files.")
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Tools") {
                LabeledContent {
                    HStack {
                        Text(model.ytDlpVersion ?? "…")
                        if model.isUpdatingYtDlp {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Update") { Task { await model.updateYtDlp() } }
                                .help("Get the latest yt-dlp. Fixes most “download failed” problems after YouTube changes.")
                        }
                    }
                } label: {
                    Text("yt-dlp")
                    if let result = model.ytDlpUpdateResult {
                        Text(result)
                    } else if model.isUpdatingYtDlp {
                        Text("Checking for a newer version…")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task { await model.loadYtDlpVersion() }
    }
}

/// Lets you build the file name from parts, without knowing any template syntax.
struct FileNameSettings: View {
    @Binding var format: FileNameFormat
    let title: String
    /// What the choice applies to, shown under the controls.
    let note: String

    private static let separators: [(label: String, value: String)] = [
        ("Dash ( - )", " - "), ("Underscore ( _ )", "_"), ("Dot ( . )", ". "), ("Space", " "),
    ]

    var body: some View {
        Section {
            LabeledContent("Example") {
                Text(format.example)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Left to right, the way the parts appear in the name.
            HStack(spacing: 8) {
                ForEach(Array(format.order.enumerated()), id: \.element) { position, part in
                    HStack(spacing: 4) {
                        Toggle(Self.label(part), isOn: Binding(
                            get: { format.included.contains(part) },
                            set: { on in
                                if on { format.included.insert(part) } else { format.included.remove(part) }
                            }))
                        .toggleStyle(.checkbox)
                        Button {
                            moveRight(position)
                        } label: {
                            Image(systemName: "arrow.right")
                        }
                        .buttonStyle(.borderless)
                        .help(position == format.order.count - 1 ? "Move to the front" : "Move one place to the right")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer(minLength: 0)
            }
            Picker("Between the parts", selection: $format.separator) {
                ForEach(Self.separators, id: \.value) { Text($0.label).tag($0.value) }
            }
            Picker("Number style", selection: $format.numberDigits) {
                Text("1, 2, 3").tag(1)
                Text("01, 02, 03").tag(2)
                Text("001, 002, 003").tag(3)
            }
            .disabled(!format.included.contains(.number))
            TextField("Text before", text: $format.prefix, prompt: Text("Nothing"))
            TextField("Text after", text: $format.suffix, prompt: Text("Nothing"))
            if format != .standard {
                Button("Reset to default") { format = .standard }
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tick the parts you want. The arrow moves a part one place to the right, and the last one back to the front. \(note)")
                if format.canCollide {
                    Label("Without the number, two songs with the same name are saved as one file.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One place later in the name; from the end it wraps round to the start.
    private func moveRight(_ position: Int) {
        if position == format.order.count - 1 {
            format.order.insert(format.order.removeLast(), at: 0)
        } else {
            format.order.swapAt(position, position + 1)
        }
    }

    private static func label(_ part: FileNameFormat.Part) -> String {
        switch part {
        case .number: "Number"
        case .artist: "Artist"
        case .title: "Title"
        }
    }
}
