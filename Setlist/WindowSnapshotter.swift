#if DEBUG
import AppKit

/// Debug builds launched with `-snapshotDir <folder>` save a picture of the main window there a few
/// times a second, drawn by the app itself. It is how the screenshots and the demo clip on the website
/// are made: no screen-recording permission is involved and nothing but this window is in the frame.
/// `-snapshotWidth` and `-snapshotHeight` set the window's size first.
@MainActor
final class WindowSnapshotter {
    static let shared = WindowSnapshotter()

    private var timer: Timer?
    private var count = 0

    func startIfAsked(defaults: UserDefaults = .standard) {
        guard timer == nil, let path = defaults.string(forKey: "snapshotDir") else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = defaults.double(forKey: "snapshotWidth"), height = defaults.double(forKey: "snapshotHeight")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                guard let window = Self.mainWindow else { return }
                if width > 0, height > 0, window.frame.size != CGSize(width: width, height: height) {
                    window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: width, height: height)), display: true)
                }
                self.capture(window, into: dir)
            }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.title != "Setlist Help" && $0.contentView != nil }
    }

    /// `CGWindowListCreateImage`, looked up by name: the SDK no longer declares it, but it is the one call
    /// that pictures a window as it is on screen (sidebar material, toolbar, shadow) and it needs no
    /// permission for the app's own windows.
    private typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let windowImage: WindowImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: WindowImage.self)
    }()

    private func capture(_ window: NSWindow, into dir: URL) {
        let onlyThisWindow: UInt32 = 1 << 3, bestResolution: UInt32 = 1 << 3
        guard let image = Self.windowImage?(.null, onlyThisWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        count += 1
        try? data.write(to: dir.appendingPathComponent(String(format: "frame-%05d.png", count)))
    }
}
#endif
