import AppKit
import Combine
import UniformTypeIdentifiers

struct Recent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case image, color }
    let kind: Kind
    let value: String  // file path or hex
    var id: String { "\(kind.rawValue):\(value)" }
    var title: String { kind == .image ? (value as NSString).lastPathComponent : "Color #\(value)" }
}

/// Desktop wallpaper and screen saver control: Apple presets, images, colors, folder rotation.
@MainActor
final class Wallpapers: ObservableObject {
    static let shared = Wallpapers()

    @Published private(set) var desktop = WallpaperStore.Summary.unknown
    @Published private(set) var screenSaver = WallpaperStore.Summary.unknown
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var recents: [Recent] = []
    @Published private(set) var busy = false
    @Published private(set) var applyingID: UUID?
    @Published private(set) var currentDesktop: NSDictionary?  // effective Content dicts, for "selected" rings
    @Published private(set) var currentIdle: NSDictionary?

    var desktopPresets: [Preset] { presets.filter { $0.kind == .desktop } }
    var screenSaverPresets: [Preset] { presets.filter { $0.kind == .idle } }

    private let engine = Engine.shared
    private let fm = FileManager.default
    private let presetsURL: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshPending = false
    private var timer: Timer?
    private var unlockObserver: NSObjectProtocol?
    private var colorWork: DispatchWorkItem?

    private init() {
        presetsURL = engine.supportDir.appending(path: "presets.plist")
        loadPresets()
        if let data = UserDefaults.standard.data(forKey: Keys.recents),
           let list = try? JSONDecoder().decode([Recent].self, from: data) { recents = list }
        refresh()
        watchStore()
        scheduleRotation()
        // Rotation pauses while locked; pick it back up once the desktop is restored.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRotation(notBefore: 10) }
        }
    }

    // MARK: Current state

    func refresh() {
        guard !engine.storeIsOurs(), let store = WallpaperStore.read() else { return }  // skip while lock image is up
        let d = WallpaperStore.effective(.desktop, in: store), i = WallpaperStore.effective(.idle, in: store)
        desktop = WallpaperStore.describe(d)
        screenSaver = WallpaperStore.describe(i)
        currentDesktop = (d?["Content"] as? [String: Any]).map { NSDictionary(dictionary: $0) }
        currentIdle = (i?["Content"] as? [String: Any]).map { NSDictionary(dictionary: $0) }
    }

    func isCurrent(_ preset: Preset) -> Bool {
        guard let content = preset.entry["Content"] as? [String: Any] else { return false }
        return (preset.kind == .desktop ? currentDesktop : currentIdle)?.isEqual(to: content) == true
    }

    func isCurrent(_ recent: Recent) -> Bool {
        switch (recent.kind, desktop.preview) {
        case (.image, .image(let path)): path == recent.value
        case (.color, .color(let hex)): hex == recent.value
        default: false
        }
    }

    private func watchStore() {
        let fd = open(WallpaperStore.url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.refreshPending else { return }
                self.refreshPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    // MARK: Apple presets

    func saveCurrent(_ kind: WallpaperStore.Kind, name: String) {
        guard !engine.storeIsOurs(), let store = WallpaperStore.read(),
              let entry = WallpaperStore.effective(kind, in: store) else {
            return engine.log("Couldn't read the current \(kind == .desktop ? "wallpaper" : "screen saver")")
        }
        let preset = Preset(name: name, kind: kind, entry: entry)
        presets.append(preset)
        savePresets()
        engine.log("Saved \(kind == .desktop ? "wallpaper" : "screen saver") “\(name)” (\(preset.summary.title))")
    }

    func apply(_ preset: Preset) {
        guard !busy else { return }
        guard !engine.storeIsOurs(), let store = WallpaperStore.read(),
              let d = WallpaperStore.effective(.desktop, in: store),
              let i = WallpaperStore.effective(.idle, in: store) else {
            return engine.log("Couldn't apply “\(preset.name)” — wallpaper store unreadable")
        }
        if preset.kind == .desktop { stopRotation() }
        let desktopEntry = preset.kind == .desktop ? WallpaperStore.stamped(preset.entry) : d
        let idleEntry = preset.kind == .idle ? WallpaperStore.stamped(preset.entry) : i
        let target = WallpaperStore.compose(desktop: desktopEntry, idle: idleEntry, base: store)
        busy = true
        applyingID = preset.id
        WallpaperStore.apply(target, holds: { now in
            WallpaperStore.sameContent(WallpaperStore.effective(preset.kind, in: now), preset.entry)
        }) { [weak self] ok, attempts in
            guard let self else { return }
            self.busy = false
            self.applyingID = nil
            self.refresh()
            self.engine.log(ok ? "Applied “\(preset.name)”" + (attempts > 1 ? " (attempt \(attempts))" : "")
                               : "Couldn't apply “\(preset.name)” after \(attempts) attempts")
        }
    }

    func rename(_ preset: Preset, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i].name = name
        savePresets()
    }

    func delete(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    private func loadPresets() {
        guard let data = try? Data(contentsOf: presetsURL),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return }
        presets = list.compactMap(Preset.init(plist:))
    }

    private func savePresets() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: presets.map(\.plist), format: .binary, options: 0)
            try data.write(to: presetsURL, options: .atomic)
        } catch {
            engine.log("Couldn't save presets — \(error.localizedDescription)")
        }
    }

    // MARK: Images and colors

    func setImage(_ url: URL, fromRotation: Bool = false) {
        guard !engine.storeIsOurs() else { return }
        let bg = NSColor(hex: Prefs.desktopBackgroundHex) ?? .black
        do {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Prefs.desktopScaling.options(background: bg))
            }
            Prefs.desktopImagePath = url.path
            if !fromRotation {
                stopRotation()
                remember(Recent(kind: .image, value: url.path))
            }
            engine.log("Desktop → \(url.lastPathComponent)")
        } catch {
            engine.log("Couldn't set desktop to \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// Re-applies the last image picked here with the current scaling, if it's still the desktop.
    func reapplyImage() {
        let path = Prefs.desktopImagePath
        guard !path.isEmpty, desktop.title == (path as NSString).lastPathComponent,
              fm.fileExists(atPath: path) else { return }
        setImage(URL(fileURLWithPath: path), fromRotation: Prefs.rotationEnabled)
    }

    /// Applies as the color well moves, without creating a file per intermediate color.
    func setColorSoon(_ hex: String) {
        colorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setColor(hex) }
        colorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func setColor(_ hex: String) {
        guard !engine.storeIsOurs() else { return }
        do {
            let url = try SolidImage.make(hex: hex, prefix: "lockwall-desktop-color-", in: engine.supportDir)
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: SolidImage.options)
            }
            stopRotation()
            remember(Recent(kind: .color, value: hex))
            pruneColorFiles()
            engine.log("Desktop → color #\(hex)")
        } catch {
            engine.log("Couldn't set desktop color — \(error.localizedDescription)")
        }
    }

    func apply(_ recent: Recent) {
        switch recent.kind {
        case .image: setImage(URL(fileURLWithPath: recent.value))
        case .color: setColor(recent.value)
        }
    }

    private func remember(_ item: Recent) {
        recents.removeAll { $0 == item }
        recents.insert(item, at: 0)
        recents = Array(recents.prefix(6))
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Keys.recents) }
    }

    private func pruneColorFiles() {
        let recentHexes = recents.filter { $0.kind == .color }.map(\.value)
        let presetHexes = presets.compactMap { p -> String? in
            if case .color(let hex) = p.summary.preview { hex } else { nil }
        }
        let keep = Set((recentHexes + presetHexes).map { "lockwall-desktop-color-\($0).png" })
        let files = (try? fm.contentsOfDirectory(atPath: engine.supportDir.path)) ?? []
        for f in files where f.hasPrefix("lockwall-desktop-color-") && !keep.contains(f) {
            try? fm.removeItem(at: engine.supportDir.appending(path: f))
        }
    }

    // MARK: Folder rotation

    func startRotation() {
        guard !Prefs.rotationFolder.isEmpty else { return }
        Prefs.rotationEnabled = true
        engine.log("Rotating desktop from \((Prefs.rotationFolder as NSString).lastPathComponent)")
        nextWallpaper()
    }

    func stopRotation() {
        guard Prefs.rotationEnabled else { return }
        Prefs.rotationEnabled = false
        scheduleRotation()
        engine.log("Desktop rotation stopped")
    }

    func nextWallpaper() {
        let folder = URL(fileURLWithPath: Prefs.rotationFolder)
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentTypeKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { return engine.log("No images in \(folder.lastPathComponent)") }
        let current = Prefs.rotationCurrent
        let next: URL
        if Prefs.rotationShuffle {
            next = files.filter { $0.path != current }.randomElement() ?? files[0]
        } else {
            let i = files.firstIndex { $0.path == current }.map { ($0 + 1) % files.count } ?? 0
            next = files[i]
        }
        Prefs.rotationCurrent = next.path
        Prefs.rotationLast = Date().timeIntervalSince1970
        setImage(next, fromRotation: true)
        scheduleRotation()
    }

    /// One timer, only while rotating, due at the next change; tolerance lets macOS batch the wakeup.
    func scheduleRotation(notBefore delay: TimeInterval = 1) {
        timer?.invalidate()
        timer = nil
        guard Prefs.rotationEnabled else { return }
        let due = Date(timeIntervalSince1970: Prefs.rotationLast + Double(Prefs.rotationInterval))
        let t = Timer(fire: max(due, Date().addingTimeInterval(delay)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotationTick() }
        }
        t.tolerance = max(5, Double(Prefs.rotationInterval) * 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func rotationTick() {
        guard Prefs.rotationEnabled else { return }
        if engine.isLocked { return }  // never rotate under the lock screen; unlock reschedules
        if engine.storeIsOurs() || busy { return scheduleRotation(notBefore: 15) }  // mid-restore or applying
        if Date().timeIntervalSince1970 - Prefs.rotationLast >= Double(Prefs.rotationInterval) - 1 {
            nextWallpaper()
        } else {
            scheduleRotation()
        }
    }

    // MARK: Screen saver timing

    var idleTime: Int {
        get { SystemSettings.idleTime }
        set {
            SystemSettings.idleTime = newValue
            objectWillChange.send()
            engine.log("Screen saver starts after \(newValue == 0 ? "never" : "\(newValue / 60) min")")
        }
    }
}

enum SolidImage {
    static let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true,
    ]

    /// A tiny PNG of one color; the hex goes in the filename because WallpaperAgent caches by URL.
    static func make(hex: String, prefix: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: "\(prefix)\(hex).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
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
}
