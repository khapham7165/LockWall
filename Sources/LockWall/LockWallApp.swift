import SwiftUI

@main
struct LockWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = Engine.shared
    @StateObject private var wallpapers = Wallpapers.shared
    @AppStorage(Keys.enabled) private var enabled = true
    @AppStorage(Keys.showInMenuBar) private var showInMenuBar = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuContent().environmentObject(engine).environmentObject(wallpapers)
        } label: {
            Image(systemName: engine.problem != nil ? "exclamationmark.triangle" : (enabled ? "lock.display" : "display"))
                .accessibilityLabel("LockWall")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if !UserDefaults.standard.bool(forKey: Keys.hasOnboarded) { WelcomeWindow.shared.show() }
        }
    }

    // The menu bar icon can be hidden or crowded out, so reopening the app must always reach Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
        return false
    }

    // A menu bar app keeps running with no windows open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.restoreBeforeQuit() }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var wallpapers: Wallpapers
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
                Button("Save Current Wallpaper…") { SettingsWindow.shared.show(.desktop) }
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
            Button("Screen Saver Settings…") { SettingsWindow.shared.show(.screenSaver) }
        }

        Divider()

        Button("Settings…") { SettingsWindow.shared.show() }
            .keyboardShortcut(",")
        Button("Quit LockWall") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
