import AppKit
import Combine

/// Swaps the desktop wallpaper to the lock wallpaper on lock and restores the saved one on unlock.
/// macOS draws the lock screen from the live desktop wallpaper, so this is the only lever available.
@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var status = "Waiting for the screen to lock"
    @Published private(set) var logLines: [String] = []
    @Published private(set) var isPreviewing = false
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var hasSavedDesktop = false

    let supportDir: URL
    let logURL: URL
    private let storeURL: URL
    private let savedURL: URL
    private let fm = FileManager.default
    // Every lock image we hand to macOS carries this in its filename, so the store tells us if it's ours.
    private let marker = Data("lockwall-lockimage-".utf8)
    private var isLocked = false
    private var observers: [NSObjectProtocol] = []
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        let home = fm.homeDirectoryForCurrentUser
        supportDir = home.appending(path: "Library/Application Support/LockWall")
        storeURL = home.appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        savedURL = supportDir.appending(path: "desktop-config.plist")
        logURL = home.appending(path: "Library/Logs/LockWall.log")
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        Prefs.registerDefaults()

        let legacy = home.appending(path: ".lockwall/good.plist")
        if !fm.fileExists(atPath: savedURL.path), fm.fileExists(atPath: legacy.path) {
            try? fm.copyItem(at: legacy, to: savedURL)
        }
        hasSavedDesktop = fm.fileExists(atPath: savedURL.path)
        loadLogTail()
        loadPreviewImage()

        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked() }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenUnlocked() }
        })

        log("LockWall started")
        restore(reason: "Launch")  // recover if we quit or crashed while locked
    }

    // MARK: Lock / unlock

    private func screenLocked() {
        isLocked = true
        guard Prefs.enabled else { return log("Locked (LockWall is off)") }
        applyLockWallpaper(reason: "Locked")
    }

    private func screenUnlocked() {
        isLocked = false
        restore(reason: "Unlocked")
    }

    @discardableResult
    private func applyLockWallpaper(reason: String) -> Bool {
        do {
            // Never snapshot our own lock image, or a failed restore would make it the "real" wallpaper.
            if !storeIsOurs() {
                try Data(contentsOf: storeURL).write(to: savedURL, options: .atomic)
                hasSavedDesktop = true
            }
            let (url, options, desc) = try lockWallpaper()
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            }
            log("\(reason) → \(desc)")
            return true
        } catch {
            log("\(reason): couldn't apply lock wallpaper — \(error.localizedDescription)")
            return false
        }
    }

    func restore(reason: String, attempt: Int = 1) {
        guard storeIsOurs() else {
            if reason == "Manual" { log("Desktop wallpaper is already in place") }
            return
        }
        do {
            try Data(contentsOf: savedURL).write(to: storeURL, options: .atomic)
        } catch {
            return log("\(reason): no saved desktop wallpaper to restore — pick one in Wallpaper settings")
        }
        killWallpaperAgent()
        DispatchQueue.main.asyncAfter(deadline: .now() + Prefs.restoreDelay) { [weak self] in
            guard let self else { return }
            if !self.storeIsOurs() {
                self.log("\(reason) → desktop wallpaper restored" + (attempt > 1 ? " (attempt \(attempt))" : ""))
            } else if attempt < Prefs.maxRetries {
                self.restore(reason: reason, attempt: attempt + 1)
            } else {
                self.log("\(reason): gave up restoring after \(attempt) attempts")
            }
        }
    }

    /// Best-effort synchronous restore for app termination; no time to verify.
    func restoreBeforeQuit() {
        guard storeIsOurs(), let data = try? Data(contentsOf: savedURL) else { return }
        try? data.write(to: storeURL, options: .atomic)
        killWallpaperAgent()
    }

    func preview(seconds: Double = 5) {
        guard !isPreviewing else { return }
        isPreviewing = true
        guard applyLockWallpaper(reason: "Preview") else { isPreviewing = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.isPreviewing = false
            if !self.isLocked { self.restore(reason: "Preview ended") }  // if locked, unlock restores
        }
    }

    // MARK: Lock image

    func importImage(from source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        // Fresh filename per import: WallpaperAgent caches by URL.
        let dest = supportDir.appending(path: "lockwall-lockimage-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try fm.copyItem(at: source, to: dest)
            let old = Prefs.imagePath
            if !old.isEmpty, old != dest.path { try? fm.removeItem(atPath: old) }
            Prefs.imagePath = dest.path
            Prefs.imageName = source.lastPathComponent
            Prefs.style = .image
            loadPreviewImage()
            log("Lock image set to \(source.lastPathComponent)")
        } catch {
            log("Couldn't import \(source.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    private func loadPreviewImage() {
        let path = Prefs.imagePath
        previewImage = path.isEmpty ? nil : NSImage(contentsOfFile: path)
    }

    private func lockWallpaper() throws -> (URL, [NSWorkspace.DesktopImageOptionKey: Any], String) {
        let solid: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true,
        ]
        switch Prefs.style {
        case .black:
            return (try solidImage("000000"), solid, "black")
        case .color:
            return (try solidImage(Prefs.colorHex), solid, "color #\(Prefs.colorHex)")
        case .image:
            let path = Prefs.imagePath
            guard !path.isEmpty, fm.fileExists(atPath: path) else {
                return (try solidImage("000000"), solid, "black (no image chosen)")
            }
            let bg = NSColor(hex: Prefs.backgroundHex) ?? .black
            return (URL(fileURLWithPath: path), Prefs.scaling.options(background: bg), "image \(Prefs.imageName)")
        }
    }

    private func solidImage(_ hex: String) throws -> URL {
        let url = supportDir.appending(path: "lockwall-lockimage-color-\(hex).png")
        if fm.fileExists(atPath: url.path) { return url }
        let size = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (NSColor(hex: hex) ?? .black).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
        return url
    }

    // MARK: Helpers

    private func storeIsOurs() -> Bool {
        guard let data = try? Data(contentsOf: storeURL) else { return false }
        return data.range(of: marker) != nil
    }

    private func killWallpaperAgent() {
        // SIGKILL: on SIGTERM WallpaperAgent may flush its in-memory lock image over our restore.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["-9", "WallpaperAgent"]
        try? p.run()
        p.waitUntilExit()
    }

    private func log(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)"
        status = message
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private func loadLogTail() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        logLines = Array(text.split(separator: "\n").suffix(200).map(String.init))
    }

    func clearLog() {
        try? Data().write(to: logURL)
        logLines = []
    }
}
