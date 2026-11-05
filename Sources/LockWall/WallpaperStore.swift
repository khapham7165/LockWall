import AppKit

/// Reads and rewrites macOS's private wallpaper store (Index.plist). Format observed on macOS 14–27.
enum WallpaperStore {
    enum Kind: String { case desktop = "Desktop", idle = "Idle" }
    typealias Entry = [String: Any]  // {Content, LastSet, LastUse}
    typealias Store = [String: Any]

    struct Summary: Equatable {
        enum Preview: Equatable { case image(String), color(String), appleColor(String), symbol }
        var title: String
        var symbol: String
        var preview: Preview = .symbol
        static let unknown = Summary(title: "Unknown", symbol: "questionmark.square.dashed")
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    static func read() -> Store? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? Store
    }

    static func write(_ store: Store) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// The entry macOS is showing: the most recently set one anywhere outside SystemDefault.
    static func effective(_ kind: Kind, in store: Store) -> Entry? {
        var best: (Date, Entry)?
        func walk(_ node: Any) {
            guard let dict = node as? [String: Any] else { return }
            if let e = dict[kind.rawValue] as? Entry, e["Content"] != nil {
                let date = e["LastSet"] as? Date ?? .distantPast
                if best == nil || date > best!.0 { best = (date, e) }
            }
            for (key, value) in dict where key != kind.rawValue { walk(value) }
        }
        for (key, value) in store where key != "SystemDefault" { walk(value) }
        if best == nil, let fallback = store["SystemDefault"] { walk(fallback) }
        return best?.1
    }

    /// One wallpaper + one screen saver for all Spaces and displays — the shape a fresh store has.
    static func compose(desktop: Entry, idle: Entry, base: Store) -> Store {
        var out = base
        out["AllSpacesAndDisplays"] = ["Desktop": desktop, "Idle": idle, "Type": "individual"] as [String: Any]
        out["Displays"] = [String: Any]()
        out["Spaces"] = [String: Any]()
        return out
    }

    static func stamped(_ entry: Entry) -> Entry {
        var e = entry
        e["LastSet"] = Date()
        e["LastUse"] = Date()
        return e
    }

    static func sameContent(_ a: Entry?, _ b: Entry?) -> Bool {
        guard let ca = a?["Content"] as? [String: Any], let cb = b?["Content"] as? [String: Any] else { return false }
        return NSDictionary(dictionary: ca).isEqual(to: cb)
    }

    static func killAgent() {
        // SIGKILL: on SIGTERM WallpaperAgent may flush its in-memory state over what we just wrote.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["-9", "WallpaperAgent"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Writes the store, restarts WallpaperAgent (it only reads the store at launch) and retries until `holds` passes.
    @MainActor
    static func apply(_ store: Store, attempt: Int = 1, holds: @escaping (Store) -> Bool,
                      completion: @escaping (_ ok: Bool, _ attempts: Int) -> Void) {
        do { try write(store) } catch { return completion(false, attempt) }
        killAgent()
        DispatchQueue.main.asyncAfter(deadline: .now() + Prefs.restoreDelay) {
            if let now = read(), holds(now) { completion(true, attempt) }
            else if attempt < Prefs.maxRetries { apply(store, attempt: attempt + 1, holds: holds, completion: completion) }
            else { completion(false, attempt) }
        }
    }

    static func describe(_ entry: Entry?) -> Summary {
        guard let content = entry?["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first,
              let provider = choice["Provider"] as? String else { return .unknown }
        let config = (choice["Configuration"] as? Data)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any] ?? [:]
        var summary: Summary
        switch provider.components(separatedBy: ".").last ?? "" {
        case "color":
            if let name = (config["systemColor"] as? [String: Any])?.keys.first {
                summary = Summary(title: "\(name.capitalized) (Apple color)", symbol: "paintpalette", preview: .appleColor(name))
            } else {
                summary = Summary(title: "Color", symbol: "paintpalette")
            }
        case "image":
            let path = ((config["url"] as? [String: Any])?["relative"] as? String).flatMap { URL(string: $0)?.path } ?? ""
            let file = (path as NSString).lastPathComponent
            if file.hasPrefix("lockwall-desktop-color-") {
                let hex = file.dropFirst("lockwall-desktop-color-".count).prefix(6)
                summary = Summary(title: "Color #\(hex)", symbol: "paintpalette", preview: .color(String(hex)))
            } else if file.hasPrefix("lockwall-lockimage-") {
                summary = Summary(title: "LockWall lock wallpaper", symbol: "lock.display")
            } else {
                summary = Summary(title: file.isEmpty ? "Image" : file, symbol: "photo", preview: path.isEmpty ? .symbol : .image(path))
            }
        case "aerials":
            summary = Summary(title: "Aerial", symbol: "film")
        case "macintosh":
            summary = Summary(title: "Macintosh", symbol: "desktopcomputer")
        case let other where other.contains("screen-saver") || other.contains("legacy"):
            summary = Summary(title: "Classic screen saver", symbol: "tv")
        case let other:
            summary = Summary(title: other.replacingOccurrences(of: "-", with: " ").capitalized, symbol: "photo.artframe")
        }
        if let shuffle = content["Shuffle"] as? String, shuffle != "$null" { summary.title += " · Shuffle" }
        if content["Shuffle"] is [String: Any] { summary.title += " · Shuffle" }
        return summary
    }
}

/// A named snapshot of one Apple wallpaper or screen saver entry, re-applied verbatim.
struct Preset: Identifiable {
    let id: UUID
    var name: String
    let kind: WallpaperStore.Kind
    let entry: WallpaperStore.Entry
    var summary: WallpaperStore.Summary { WallpaperStore.describe(entry) }

    var plist: [String: Any] { ["id": id.uuidString, "name": name, "kind": kind.rawValue, "entry": entry] }

    init(name: String, kind: WallpaperStore.Kind, entry: WallpaperStore.Entry) {
        id = UUID(); self.name = name; self.kind = kind; self.entry = entry
    }

    init?(plist: [String: Any]) {
        guard let id = (plist["id"] as? String).flatMap(UUID.init), let name = plist["name"] as? String,
              let kind = (plist["kind"] as? String).flatMap(WallpaperStore.Kind.init),
              let entry = plist["entry"] as? WallpaperStore.Entry else { return nil }
        self.id = id; self.name = name; self.kind = kind; self.entry = entry
    }
}

/// Screen saver timing and hot corners, stored in regular system preference domains.
enum SystemSettings {
    static var idleTime: Int {
        get {
            CFPreferencesCopyValue("idleTime" as CFString, "com.apple.screensaver" as CFString,
                                   kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int ?? 0
        }
        set {
            CFPreferencesSetValue("idleTime" as CFString, newValue as CFNumber, "com.apple.screensaver" as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize("com.apple.screensaver" as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
    }

    static func startScreenSaver() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                                           configuration: .init())
    }

    enum Corner: String, CaseIterable, Identifiable {
        case tl, tr, bl, br
        var id: Self { self }
        var title: String {
            switch self {
            case .tl: "Top Left"
            case .tr: "Top Right"
            case .bl: "Bottom Left"
            case .br: "Bottom Right"
            }
        }
    }

    enum CornerAction: Int, CaseIterable, Identifiable {
        case none = 1, missionControl = 2, appWindows = 3, desktop = 4, startScreenSaver = 5,
             disableScreenSaver = 6, displaySleep = 10, notificationCenter = 12, lockScreen = 13, quickNote = 14
        var id: Self { self }
        var title: String {
            switch self {
            case .none: "—"
            case .missionControl: "Mission Control"
            case .appWindows: "Application Windows"
            case .desktop: "Desktop"
            case .startScreenSaver: "Start Screen Saver"
            case .disableScreenSaver: "Disable Screen Saver"
            case .displaySleep: "Put Display to Sleep"
            case .notificationCenter: "Notification Center"
            case .lockScreen: "Lock Screen"
            case .quickNote: "Quick Note"
            }
        }
    }

    private static let dock = "com.apple.dock" as CFString

    static func hotCorner(_ corner: Corner) -> CornerAction {
        let raw = CFPreferencesCopyAppValue("wvous-\(corner.rawValue)-corner" as CFString, dock) as? Int ?? 1
        return CornerAction(rawValue: raw) ?? .none
    }

    static func setHotCorner(_ corner: Corner, to action: CornerAction) {
        CFPreferencesSetAppValue("wvous-\(corner.rawValue)-corner" as CFString, action.rawValue as CFNumber, dock)
        CFPreferencesSetAppValue("wvous-\(corner.rawValue)-modifier" as CFString, 0 as CFNumber, dock)
        CFPreferencesAppSynchronize(dock)
        let p = Process()  // Dock only rereads hot corners on launch
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}
