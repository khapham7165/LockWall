import SwiftUI

@main
struct LockWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = Engine.shared
    @StateObject private var wallpapers = Wallpapers.shared
    @AppStorage(Keys.enabled) private var enabled = true
    @AppStorage(Keys.showInMenuBar) private var showInMenuBar = true
    @AppStorage(Keys.hasOnboarded) private var hasOnboarded = false

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuContent().environmentObject(engine).environmentObject(wallpapers)
        } label: {
            Image(systemName: engine.problem != nil ? "exclamationmark.triangle" : (enabled ? "lock.display" : "display"))
                .accessibilityLabel("LockWall")
        }

        Settings {
            SettingsView().environmentObject(engine).environmentObject(wallpapers)
        }

        Window("Welcome to LockWall", id: "welcome") {
            WelcomeView().environmentObject(engine)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(hasOnboarded ? .suppressed : .presented)
    }
}

/// Opens Settings, optionally on a given pane; needs a live view's `openSettings`.
@MainActor
func showSettings(_ pane: SettingsPane? = nil, using openSettings: OpenSettingsAction) {
    if let pane { UserDefaults.standard.set(pane.rawValue, forKey: Keys.settingsPane) }
    NSApp.activate()
    openSettings()
}

/// Hosts a throwaway view just to reach `openSettings` (macOS ignores showSettingsWindow: since 14).
private struct SettingsBridge: View {
    @Environment(\.openSettings) private var openSettings
    let done: () -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .onAppear {
                showSettings(using: openSettings)
                done()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var bridge: NSWindow?

    // The menu bar icon can be hidden or crowded out, so reopening the app must always reach Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            let window = NSWindow(contentRect: NSRect(x: -100, y: -100, width: 1, height: 1),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentView = NSHostingView(rootView: SettingsBridge { [weak self] in
                DispatchQueue.main.async { self?.bridge?.close(); self?.bridge = nil }
            })
            window.orderFront(nil)
            bridge = window
        }
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.restoreBeforeQuit() }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var wallpapers: Wallpapers
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Keys.enabled) private var enabled = true
    @AppStorage(Keys.style) private var style = LockStyle.black
    @AppStorage(Keys.rotationEnabled) private var rotating = false

    var body: some View {
        if let problem = engine.problem {
            Button {
                engine.restore(reason: "Manual")
            } label: {
                Label("\(problem) — Retry", systemImage: "exclamationmark.triangle")
            }
            Divider()
        }

        Section("Lock Screen") {
            Toggle("Separate Lock Screen Wallpaper", isOn: $enabled)
            Picker("Lock Screen Wallpaper", selection: $style) {
                ForEach(LockStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .disabled(!enabled)
            Button("Lock Screen Now") { engine.lockNow() }
        }

        Divider()

        Section("Desktop") {
            if wallpapers.desktopPresets.isEmpty {
                Button("Save Current Wallpaper…") { showSettings(.desktop, using: openSettings) }
            }
            ForEach(wallpapers.desktopPresets) { preset in
                Toggle(isOn: Binding(get: { wallpapers.isCurrent(preset) }, set: { _ in wallpapers.apply(preset) })) {
                    Label {
                        Text(preset.name)
                    } icon: {
                        Image(nsImage: Thumbnails.menuIcon(preset.summary.preview, symbol: preset.summary.symbol))
                    }
                }
                .disabled(wallpapers.busy)
            }
            Menu("Recent") {
                ForEach(wallpapers.recents) { recent in
                    Button {
                        wallpapers.apply(recent)
                    } label: {
                        Label {
                            Text(recent.title)
                        } icon: {
                            Image(nsImage: Thumbnails.menuIcon(recent.kind == .image ? .image(recent.value) : .color(recent.value),
                                                               symbol: "photo"))
                        }
                    }
                }
            }
            .disabled(wallpapers.recents.isEmpty)
            Button("Next Wallpaper") { wallpapers.nextWallpaper() }
                .disabled(!rotating)
        }

        Divider()

        Menu("Screen Saver") {
            ForEach(wallpapers.screenSaverPresets) { preset in
                Toggle(preset.name, isOn: Binding(get: { wallpapers.isCurrent(preset) }, set: { _ in wallpapers.apply(preset) }))
                    .disabled(wallpapers.busy)
            }
            if !wallpapers.screenSaverPresets.isEmpty { Divider() }
            Button("Start Screen Saver") { SystemSettings.startScreenSaver() }
            Button("Screen Saver Settings…") { showSettings(.screenSaver, using: openSettings) }
        }

        Divider()

        Button("Settings…") { showSettings(using: openSettings) }
            .keyboardShortcut(",")
        Button("Quit LockWall") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
