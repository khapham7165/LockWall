import SwiftUI

@main
struct LockWallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = Engine.shared
    @AppStorage(Keys.enabled) private var enabled = true

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(engine)
        } label: {
            Image(systemName: enabled ? "lock.display" : "display")
        }

        Settings {
            SettingsView().environmentObject(engine)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.restoreBeforeQuit() }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Keys.enabled) private var enabled = true
    @AppStorage(Keys.style) private var style = LockStyle.black

    var body: some View {
        Text(engine.status)
        Divider()
        Toggle("Separate Lock Screen Wallpaper", isOn: $enabled)
        Picker("Lock Wallpaper", selection: $style) {
            ForEach(LockStyle.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("Preview on Desktop") { engine.preview() }
            .disabled(engine.isPreviewing)
        Button("Restore Desktop Wallpaper") { engine.restore(reason: "Manual") }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit LockWall") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
