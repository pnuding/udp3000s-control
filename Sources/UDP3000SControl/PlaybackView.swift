import SwiftUI

struct PlaybackView: View {
    @EnvironmentObject var model: AppModel
    @State private var showFileImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback").font(.headline)
            HStack {
                Button("Choose CSV…") { showFileImporter = true }
                    .help("Load a CSV file of setpoints to play back")
                Button(model.playing ? "Stop" : "Play") {
                    if model.playing {
                        model.stopPlayback()
                    } else {
                        model.startPlayback()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.playbackRows.isEmpty)
                .help(model.playing ? "Stop playback" : "Play back the loaded CSV")
            }
            if !model.playbackStatus.isEmpty {
                Text(model.playbackStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.loadPlaybackFile(url: url)
                }
            case .failure(let error):
                model.playbackStatus = String(localized: "File selection failed: \(error.localizedDescription)")
            }
        }
    }
}
