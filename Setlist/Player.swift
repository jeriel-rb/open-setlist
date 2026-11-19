import AVFoundation
import Foundation
import Observation

/// Plays one downloaded song at a time for the mini player at the bottom of the window.
@MainActor
@Observable
final class Player {
    /// What the mini player shows; nil hides it.
    private(set) var title: String?
    private(set) var fileURL: URL?
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0

    private var audio: AVAudioPlayer?
    private var ticker: Timer?

    var isVisible: Bool { title != nil }

    /// Starts `file` from the beginning. Playing the song that is already loaded toggles pause instead.
    func play(_ file: URL, title: String) throws {
        if file == fileURL, audio != nil {
            toggle()
            return
        }
        let audio = try AVAudioPlayer(contentsOf: file)
        stopTicker()
        self.audio?.stop()
        self.audio = audio
        self.title = title
        fileURL = file
        duration = audio.duration
        currentTime = 0
        audio.play()
        isPlaying = true
        startTicker()
    }

    func toggle() {
        guard let audio else { return }
        if audio.isPlaying {
            audio.pause()
            isPlaying = false
            stopTicker()
        } else {
            // A song that ran to its end starts over.
            if audio.currentTime >= audio.duration - 0.05 { audio.currentTime = 0 }
            audio.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to time: TimeInterval) {
        guard let audio else { return }
        audio.currentTime = min(max(0, time), audio.duration)
        currentTime = audio.currentTime
    }

    /// Stops playback and hides the mini player.
    func close() {
        stopTicker()
        audio?.stop()
        audio = nil
        title = nil
        fileURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let audio else { return }
        if audio.isPlaying {
            currentTime = audio.currentTime
        } else if isPlaying {
            // Reached the end.
            isPlaying = false
            currentTime = duration
            stopTicker()
        }
    }
}
