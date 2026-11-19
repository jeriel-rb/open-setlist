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
