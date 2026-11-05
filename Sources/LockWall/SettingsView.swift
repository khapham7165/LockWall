import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            LockScreenTab().tabItem { Label("Lock Screen", systemImage: "lock.display") }
            AdvancedTab().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralTab: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage(Keys.enabled) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Use a separate lock screen wallpaper", isOn: $enabled)
                LaunchAtLoginToggle()
            } footer: {
                Text("macOS draws the lock screen from your desktop wallpaper. LockWall swaps it when the screen locks and puts yours back when you unlock.")
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Last event", value: engine.status)
                LabeledContent("Desktop wallpaper", value: engine.hasSavedDesktop ? "Saved" : "Saved on next lock")
            }
            Section {
                Button("Open Wallpaper Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                }
            } footer: {
                Text("Change your desktop wallpaper there as usual; LockWall picks it up the next time you lock.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(
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
        ))
        if status == .requiresApproval {
            LabeledContent("Needs approval in Login Items") {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error {
            Text(error).foregroundStyle(.red).font(.callout)
        }
    }
}

// MARK: Lock Screen

private struct LockScreenTab: View {
    @EnvironmentObject private var engine: Engine
    @AppStorage(Keys.style) private var style = LockStyle.black
    @AppStorage(Keys.colorHex) private var colorHex = "1C1C1E"
    @AppStorage(Keys.scaling) private var scaling = Scaling.fill
    @AppStorage(Keys.backgroundHex) private var backgroundHex = "000000"
    @AppStorage(Keys.imageName) private var imageName = ""
    @State private var choosingImage = false

    var body: some View {
        Form {
            Section {
                LockPreview()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            Section {
                Picker("Wallpaper", selection: $style) {
                    ForEach(LockStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch style {
                case .black:
                    EmptyView()
                case .color:
                    ColorPicker("Color", selection: $colorHex.asColor, supportsOpacity: false)
                case .image:
                    LabeledContent("Image") {
                        HStack {
                            Text(imageName.isEmpty ? "None" : imageName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") { choosingImage = true }
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
                LabeledContent("Try it") {
                    Button(engine.isPreviewing ? "Previewing…" : "Preview on Desktop for 5 Seconds") { engine.preview() }
                        .disabled(engine.isPreviewing)
                }
            } footer: {
                Text("Changes apply the next time the screen locks. Press ⌃⌘Q to lock now.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { engine.importImage(from: url) }
        }
    }
}

/// Approximates the lock screen: wallpaper plus the date and time.
private struct LockPreview: View {
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
                            .font(.system(size: 10, weight: .semibold))
                        Text(ctx.date, format: .dateTime.hour().minute())
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 2)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(screenSize.width / screenSize.height, contentMode: .fit)
        .frame(maxWidth: 380)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
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
                Color.black.overlay(Text("No image chosen").font(.callout).foregroundStyle(.secondary))
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
                Stepper(value: $restoreDelay, in: 0.5...10, step: 0.5) {
                    LabeledContent("Check restore after", value: "\(restoreDelay.formatted()) s")
                }
                Stepper(value: $maxRetries, in: 1...10) {
                    LabeledContent("Restore attempts", value: "\(maxRetries)")
                }
                LabeledContent("Restore now") {
                    Button("Restore Desktop Wallpaper") { engine.restore(reason: "Manual") }
                }
            } header: {
                Text("Unlock")
            } footer: {
                Text("After unlocking, LockWall restarts the system wallpaper agent and verifies your wallpaper came back, retrying if it didn't.")
                    .foregroundStyle(.secondary)
            }
            Section("Log") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(engine.logLines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 140)
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
