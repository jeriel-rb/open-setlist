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
                        Text(model.outputRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { model.chooseOutputFolder() }
                    }
                }
                Picker("Audio quality", selection: $model.audioQuality) {
                    Text("Best available").tag("0")
                    Text("192 kbps").tag("192K")
                    Text("128 kbps").tag("128K")
                }
                Toggle("Keep original mix audio", isOn: $model.keepOriginalMix)
            }
            Section("Tools") {
                LabeledContent("yt-dlp") {
                    HStack {
                        Text(model.ytDlpVersion ?? "…")
                        Button("Update") {}
                            .disabled(true)
                            .help("Available in the next build")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task { await model.loadYtDlpVersion() }
    }
}
