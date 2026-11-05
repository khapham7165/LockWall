import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String { case general, lock, desktop, screenSaver, advanced }

struct SettingsView: View {
    @AppStorage(Keys.settingsPane) private var pane = SettingsPane.lock  // restore the last-viewed pane

    var body: some View {
        TabView(selection: $pane) {
            GeneralTab().frame(width: 580, height: 340)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsPane.general)
            LockScreenTab().frame(width: 580, height: 530)
                .tabItem { Label("Lock Screen", systemImage: "lock.display") }.tag(SettingsPane.lock)
            DesktopTab().frame(width: 580, height: 700)
                .tabItem { Label("Desktop", systemImage: "photo.on.rectangle") }.tag(SettingsPane.desktop)
            ScreenSaverTab().frame(width: 580, height: 660)
                .tabItem { Label("Screen Saver", systemImage: "sparkles.tv") }.tag(SettingsPane.screenSaver)
            AdvancedTab().frame(width: 580, height: 520)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }.tag(SettingsPane.advanced)
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
    @EnvironmentObject private var engine: Engine
    @AppStorage(Keys.colorHex) private var colorHex = "1C1C1E"
    let style: LockStyle

    var body: some View {
        switch style {
        case .black:
            Color.black.overlay(miniClock)
        case .color:
            Color(nsColor: NSColor(hex: colorHex) ?? .black).overlay(miniClock)
        case .image:
            if let img = engine.previewImage {
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
    @EnvironmentObject private var engine: Engine
    @AppStorage(Keys.style) private var style = LockStyle.black
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
            if let img = engine.previewImage {
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
                    background.overlay(
                        Image(nsImage: img).resizable()
                            .frame(width: img.size.width * k, height: img.size.height * k)
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
