import Darwin
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable {
    case general, lock, desktop, screenSaver, advanced

    var title: String {
        switch self {
        case .general: "General"
        case .lock: "Lock Screen"
        case .desktop: "Desktop"
        case .screenSaver: "Screen Saver"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .lock: "lock.display"
        case .desktop: "photo.on.rectangle"
        case .screenSaver: "sparkles.tv"
        case .advanced: "gearshape.2"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralTab().frame(width: 580, height: 340)
        case .lock: LockScreenTab().frame(width: 580, height: 530)
        case .desktop: DesktopTab().frame(width: 580, height: 700)
        case .screenSaver: ScreenSaverTab().frame(width: 580, height: 660)
        case .advanced: AdvancedTab().frame(width: 580, height: 520)
        }
    }
}

/// AppKit-owned Settings window, created on demand and destroyed on close so it costs nothing while closed
/// (SwiftUI's Settings scene keeps its whole view tree alive after closing).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var tabs: PaneTabs?

    func show(_ pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: Keys.settingsPane) }
        if window == nil { build() }
        if let pane, let i = SettingsPane.allCases.firstIndex(of: pane) { tabs?.selectedTabViewItemIndex = i }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let tabs = PaneTabs()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: pane.content
                .environmentObject(Engine.shared)
                .environmentObject(Wallpapers.shared))
            host.sizingOptions = .preferredContentSize
            host.title = pane.title
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let saved = SettingsPane(rawValue: UserDefaults.standard.string(forKey: Keys.settingsPane) ?? "") ?? .lock
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: saved) ?? 0

        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]  // HIG: settings windows dim minimize and zoom
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("LockWallSettings")
        window = w
        self.tabs = tabs
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            self.window = nil
            self.tabs = nil
            Thumbnails.purge()
            // Hand the freed heap back to macOS rather than holding it until memory pressure.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
        }
    }
}

/// Remembers the last-viewed pane (HIG: restore the most recently viewed pane).
private final class PaneTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let item, let i = tabView.tabViewItems.firstIndex(of: item) {
            UserDefaults.standard.set(SettingsPane.allCases[i].rawValue, forKey: Keys.settingsPane)
        }
    }
}

/// Section footer text, left-aligned (grouped forms otherwise wrap it ragged-right).
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
func chooseImageOrFolder(directories: Bool) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !directories
    panel.canChooseDirectories = directories
    panel.allowsMultipleSelection = false
    if !directories { panel.allowedContentTypes = [.image] }
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures")
    panel.prompt = directories ? "Choose Folder" : "Choose Image"
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
}

// MARK: General

private struct GeneralTab: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Keys.enabled) private var enabled = true
    @AppStorage(Keys.showInMenuBar) private var showInMenuBar = true

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("Separate lock screen wallpaper")
                    Text("Show a different wallpaper while your Mac is locked.")
                }
            }
            Section {
                LaunchAtLoginToggle()
                Toggle(isOn: $showInMenuBar) {
                    Text("Show in menu bar")
                    if !showInMenuBar { Text("Open LockWall again from Applications or Spotlight to get back here.") }
                }
            }
            Section {
                LabeledContent("Status") { StatusBadge() }
            }
            Section {
                LabeledContent("LockWall \(version)") {
                    Button("Show Welcome…") { openWindow(id: "welcome") }
                        .accessibilityLabel("Show Welcome")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct StatusBadge: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage(Keys.enabled) private var enabled = true

    var body: some View {
        if let problem = engine.problem {
            HStack {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                Button("Retry") { engine.restore(reason: "Manual") }
            }
        } else if !enabled {
            Label("Off", systemImage: "pause.circle.fill").foregroundStyle(.secondary)
        } else if let last = engine.lastRestored {
            Label("Working · restored \(last.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
        } else {
            Label("Ready", systemImage: "checkmark.circle.fill").symbolRenderingMode(.multicolor)
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle(isOn: Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                status = SMAppService.mainApp.status
            }
        )) {
            Text("Open at login")
            if status == .requiresApproval {
                Text("Allow LockWall in System Settings → General → Login Items.")
            } else if let error {
                Text(error)
            }
        }
        if status == .requiresApproval {
            LabeledContent("") {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    .accessibilityLabel("Open Login Items")
            }
        }
    }
}

// MARK: Lock Screen

private struct LockScreenTab: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage(Keys.enabled) private var enabled = true
    @AppStorage(Keys.style) private var style = LockStyle.black
    @AppStorage(Keys.colorHex) private var colorHex = "1C1C1E"
    @AppStorage(Keys.scaling) private var scaling = Scaling.fill
    @AppStorage(Keys.backgroundHex) private var backgroundHex = "000000"
    @AppStorage(Keys.imageName) private var imageName = ""
    @AppStorage(Keys.imagePath) private var imagePath = ""

    var body: some View {
        Form {
            Section {
                VStack(spacing: 18) {
                    LockPreview()
                        .frame(width: 340)
                        .opacity(enabled ? 1 : 0.45)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first else { return false }
                            engine.importImage(from: url)
                            return true
                        }
                        .help("Drop an image here to use it on the lock screen")
                    HStack(spacing: 14) {
                        ForEach(LockStyle.allCases) { s in
                            Tile(title: s.title, selected: style == s, action: { select(s) }) {
                                LockStyleThumb(style: s)
                            }
                            .frame(width: 128)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } footer: {
                if !enabled {
                    FooterText("LockWall is off — turn on “Separate lock screen wallpaper” in General.")
                }
            }

            switch style {
            case .black:
                EmptyView()
            case .color:
                Section {
                    ColorPicker("Color", selection: $colorHex.asColor, supportsOpacity: false)
                }
            case .image:
                Section {
                    LabeledContent("Image") {
                        HStack {
                            Text(imageName.isEmpty ? "None" : imageName)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { pickImage() }
                                .accessibilityLabel("Choose lock screen image")
                        }
                    }
                    Picker("Scaling", selection: $scaling) {
                        ForEach(Scaling.allCases) { Text($0.title).tag($0) }
                    }
                    if scaling.usesBackground {
                        ColorPicker("Background", selection: $backgroundHex.asColor, supportsOpacity: false)
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("Lock Screen Now") { engine.lockNow() }
                        .disabled(!enabled)
                        .accessibilityLabel("Lock Screen Now")
                } label: {
                    Text("See it for real")
                    Text("Your desktop comes back as soon as you unlock.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func select(_ s: LockStyle) {
        if s == .image, imagePath.isEmpty {
            pickImage()  // nothing to show yet; keep the old style if they cancel
        } else {
            style = s
        }
    }

    private func pickImage() {
        if let url = chooseImageOrFolder(directories: false) { engine.importImage(from: url) }
    }
}

private struct LockStyleThumb: View {
    @AppStorage(Keys.colorHex) private var colorHex = "1C1C1E"
    @AppStorage(Keys.imagePath) private var imagePath = ""
    let style: LockStyle

    var body: some View {
        switch style {
        case .black:
            Color.black.overlay(miniClock)
        case .color:
            Color(nsColor: NSColor(hex: colorHex) ?? .black).overlay(miniClock)
        case .image:
            if let img = Thumbnails.image(imagePath, maxPixels: 320) {
                Color.clear.overlay(Image(nsImage: img).resizable().scaledToFill()).clipped().overlay(miniClock)
            } else {
                Color(nsColor: .quaternaryLabelColor)
                    .overlay(Image(systemName: "photo.badge.plus").font(.system(size: 20)).foregroundStyle(.secondary))
            }
        }
    }

    private var miniClock: some View {
        Text(Date.now, format: .dateTime.hour().minute()).font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
    }
}

/// Approximates the lock screen: wallpaper plus the date and time.
struct LockPreview: View {
    @AppStorage(Keys.style) private var style = LockStyle.black
    @AppStorage(Keys.imagePath) private var imagePath = ""
    @AppStorage(Keys.colorHex) private var colorHex = "1C1C1E"
    @AppStorage(Keys.scaling) private var scaling = Scaling.fill
    @AppStorage(Keys.backgroundHex) private var backgroundHex = "000000"

    private var screenSize: CGSize { NSScreen.main?.frame.size ?? CGSize(width: 1600, height: 1000) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                wallpaper(in: geo.size)
                TimelineView(.everyMinute) { ctx in
                    VStack(spacing: 0) {
                        Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.system(size: geo.size.width * 0.03, weight: .semibold))
                        Text(ctx.date, format: .dateTime.hour().minute())
                            .font(.system(size: geo.size.width * 0.13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .padding(.top, geo.size.height * 0.08)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: geo.size.width * 0.07))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, geo.size.height * 0.1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(screenSize.width / screenSize.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.15)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityLabel("Lock screen preview")
    }

    @ViewBuilder
    private func wallpaper(in size: CGSize) -> some View {
        let background = Color(nsColor: NSColor(hex: backgroundHex) ?? .black)
        switch style {
        case .black:
            Color.black
        case .color:
            Color(nsColor: NSColor(hex: colorHex) ?? .black)
        case .image:
            if let img = Thumbnails.image(imagePath, maxPixels: 1024) {
                switch scaling {
                case .fill:
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height).clipped()
                case .fit:
                    background.overlay(Image(nsImage: img).resizable().scaledToFit())
                case .stretch:
                    Image(nsImage: img).resizable()
                case .center:
                    let k = size.width / screenSize.width
                    let original = Thumbnails.pixelSize(imagePath) ?? img.size
                    background.overlay(
                        Image(nsImage: img).resizable()
                            .frame(width: original.width * k, height: original.height * k)
                    )
                    .clipped()
                }
            } else {
                Color.black
            }
        }
    }
}

// MARK: Advanced

private struct AdvancedTab: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage(Keys.restoreDelay) private var restoreDelay = 2.0
    @AppStorage(Keys.maxRetries) private var maxRetries = 4

    var body: some View {
        Form {
            Section {
                LabeledContent("Verify restore after") {
                    HStack(spacing: 6) {
                        Text("\(restoreDelay.formatted()) s").monospacedDigit()
                        Stepper("", value: $restoreDelay, in: 0.5...10, step: 0.5).labelsHidden()
                    }
                }
                LabeledContent("Restore attempts") {
                    HStack(spacing: 6) {
                        Text("\(maxRetries)").monospacedDigit()
                        Stepper("", value: $maxRetries, in: 1...10).labelsHidden()
                    }
                }
                LabeledContent("If your desktop stays on the lock wallpaper") {
                    Button("Restore Now") { engine.restore(reason: "Manual") }
                        .accessibilityLabel("Restore desktop wallpaper now")
                }
            } header: {
                Text("Unlock")
            } footer: {
                FooterText("After you unlock, LockWall restarts the system wallpaper service and checks your wallpaper came back, retrying if it didn't.")
            }
            Section("Activity") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(engine.logLines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 150)
                    .onAppear { proxy.scrollTo("end") }
                    .onChange(of: engine.logLines.count) { proxy.scrollTo("end") }
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([engine.logURL]) }
                    Spacer()
                    Button("Clear") { engine.clearLog() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
