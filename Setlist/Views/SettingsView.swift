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
                Toggle("Keep original mix audio", isOn: $model.keepOriginalMix)
                    .help("YouTube Set: when the mix had to be downloaded to identify it, save it in the job folder as “original mix.wav”.")
            }
            FileNameSettings(format: $model.fileNameFormat)
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Tools") {
                LabeledContent("yt-dlp") {
                    HStack {
                        Text(model.ytDlpVersion ?? "…")
                        if model.isUpdatingYtDlp {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Update") { Task { await model.updateYtDlp() } }
                                .help("Download the latest yt-dlp release. Fixes most \"download failed\" problems after YouTube changes.")
                        }
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
private struct FileNameSettings: View {
    @Binding var format: FileNameFormat

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
            ForEach(Array(format.order.enumerated()), id: \.element) { position, part in
                HStack {
                    Toggle(Self.label(part), isOn: Binding(
                        get: { format.included.contains(part) },
                        set: { on in
                            if on { format.included.insert(part) } else { format.included.remove(part) }
                        }))
                    Spacer()
                    Button {
                        format.order.swapAt(position, position - 1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(position == 0)
                    .help("Move earlier in the name")
                    Button {
                        format.order.swapAt(position, position + 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .disabled(position == format.order.count - 1)
                    .help("Move later in the name")
                }
                .buttonStyle(.borderless)
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
                Button("Back to “01 - Artist - Title”") { format = .standard }
            }
        } header: {
            Text("File names")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tick the parts you want and use the arrows to put them in order. Used for downloads you start from now on; files you already have keep their names.")
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

    private static func label(_ part: FileNameFormat.Part) -> String {
        switch part {
        case .number: "Number"
        case .artist: "Artist"
        case .title: "Title"
        }
    }
}
