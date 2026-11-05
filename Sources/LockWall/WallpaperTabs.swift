import SwiftUI
import UniformTypeIdentifiers

// MARK: Shared grid

/// Saved Apple wallpapers or screen savers as a thumbnail grid; click to apply.
struct PresetGrid: View {
    @EnvironmentObject private var wallpapers: Wallpapers
    let kind: WallpaperStore.Kind

    @State private var editing: Preset?
    @State private var naming = false
    @State private var name = ""

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 14, alignment: .top)]
    private var presets: [Preset] { kind == .desktop ? wallpapers.desktopPresets : wallpapers.screenSaverPresets }
    private var noun: String { kind == .desktop ? "Wallpaper" : "Screen Saver" }
    private var current: WallpaperStore.Summary { kind == .desktop ? wallpapers.desktop : wallpapers.screenSaver }
    private var currentIsSaved: Bool { presets.contains { wallpapers.isCurrent($0) } }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            if !currentIsSaved {
                Tile(title: "Current", subtitle: shortTitle(current), selected: true, action: {}) {
                    EntryThumbnail(summary: current)
                }
                .contextMenu { Button("Save…") { startSaving() } }
                .help("Not saved yet — use + to save it")
            }
            ForEach(presets) { preset in
                Tile(title: preset.name, subtitle: shortTitle(preset.summary), selected: wallpapers.isCurrent(preset),
                     busy: wallpapers.applyingID == preset.id, action: { wallpapers.apply(preset) }) {
                    EntryThumbnail(summary: preset.summary)
                }
                .disabled(wallpapers.busy && wallpapers.applyingID != preset.id)
                .contextMenu {
                    Button("Rename…") { editing = preset; name = preset.name; naming = true }
                    Divider()
                    Button("Delete", role: .destructive) { wallpapers.delete(preset) }
                }
            }
            AddTile(title: "Add") {
                Button("Save Current \(noun)") { startSaving() }
                    .disabled(currentIsSaved)
                if kind == .desktop {
                    Button("Choose Image…") {
                        if let url = chooseImageOrFolder(directories: false) { wallpapers.setImage(url) }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .alert(editing == nil ? "Save Current \(noun)" : "Rename \(noun)", isPresented: $naming) {
            TextField("Name", text: $name)
            Button(editing == nil ? "Save" : "Rename") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                if let editing { wallpapers.rename(editing, to: trimmed) } else { wallpapers.saveCurrent(kind, name: trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if editing == nil { Text("Save “\(current.title)” so you can switch back to it in one click.") }
        }
    }

    private func startSaving() {
        editing = nil
        name = shortTitle(current)
        naming = true
    }

    private func shortTitle(_ s: WallpaperStore.Summary) -> String {
        s.title.replacingOccurrences(of: " (Apple color)", with: "")
    }
}

private struct SettingsLinkButton: View {
    let title: String
    let pane: String

    var body: some View {
        Button(title) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.\(pane)-Settings.extension")!)
        }
        .buttonStyle(.link)
        .font(.callout)
    }
}

// MARK: Desktop

struct DesktopTab: View {
    @EnvironmentObject private var wallpapers: Wallpapers
    @AppStorage(Keys.desktopScaling) private var scaling = Scaling.fill
    @AppStorage(Keys.desktopBackgroundHex) private var backgroundHex = "000000"
    @AppStorage(Keys.desktopColorHex) private var colorHex = "1C1C1E"
    @AppStorage(Keys.rotationEnabled) private var rotating = false
    @AppStorage(Keys.rotationFolder) private var folder = ""
    @AppStorage(Keys.rotationInterval) private var interval = 1800
    @AppStorage(Keys.rotationShuffle) private var shuffle = true

    private let intervals: [(Int, String)] = [
        (300, "Every 5 minutes"), (900, "Every 15 minutes"), (1800, "Every 30 minutes"),
        (3600, "Every hour"), (10800, "Every 3 hours"), (86400, "Every day"),
    ]
    private let recentColumns = [GridItem(.adaptive(minimum: 88, maximum: 104), spacing: 12, alignment: .top)]

    var body: some View {
        Form {
            Section {
                PresetGrid(kind: .desktop)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        wallpapers.setImage(url)
                        return true
                    }
            } header: {
                Text("Your Wallpapers")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    FooterText("Click to switch. Apple colors, dynamic and Aerial wallpapers come back exactly as you saved them.")
                    Spacer()
                    SettingsLinkButton(title: "Wallpaper Settings…", pane: "Wallpaper")
                }
            }

            if !wallpapers.recents.isEmpty {
                Section("Recent") {
                    LazyVGrid(columns: recentColumns, spacing: 12) {
                        ForEach(wallpapers.recents) { recent in
                            Tile(title: recent.kind == .image ? (recent.title as NSString).deletingPathExtension : recent.title,
                                 selected: wallpapers.isCurrent(recent), action: { wallpapers.apply(recent) }) {
                                EntryThumbnail(summary: .init(title: recent.title, symbol: "photo",
                                                              preview: recent.kind == .image ? .image(recent.value) : .color(recent.value)))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Quick Set") {
                LabeledContent("Image") {
                    Button("Choose Image…") {
                        if let url = chooseImageOrFolder(directories: false) { wallpapers.setImage(url) }
                    }
                    .accessibilityLabel("Choose desktop image")
                }
                Picker("Image scaling", selection: $scaling) {
                    ForEach(Scaling.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: scaling) { wallpapers.reapplyImage() }
                if scaling.usesBackground {
                    ColorPicker("Image background", selection: $backgroundHex.asColor, supportsOpacity: false)
                        .onChange(of: backgroundHex) { wallpapers.reapplyImage() }
                }
                ColorPicker("Solid color", selection: Binding(
                    get: { $colorHex.asColor.wrappedValue },
                    set: { $colorHex.asColor.wrappedValue = $0; wallpapers.setColorSoon(colorHex) }
                ), supportsOpacity: false)
            }

            Section("Rotate Pictures") {
                Toggle(isOn: Binding(get: { rotating }, set: { $0 ? wallpapers.startRotation() : wallpapers.stopRotation() })) {
                    Text("Change picture automatically")
                    Text(folder.isEmpty ? "Choose a folder of images first." : "Pauses while your Mac is locked.")
                }
                .disabled(folder.isEmpty && !rotating)
                LabeledContent("Folder") {
                    HStack {
                        Text(folder.isEmpty ? "None" : (folder as NSString).lastPathComponent)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            if let url = chooseImageOrFolder(directories: true) {
                                folder = url.path
                                if rotating { wallpapers.nextWallpaper() }
                            }
                        }
                        .accessibilityLabel("Choose rotation folder")
                    }
                }
                Picker("Change picture", selection: $interval) {
                    ForEach(intervals, id: \.0) { Text($0.1).tag($0.0) }
                }
                .disabled(!rotating)
                .onChange(of: interval) { wallpapers.scheduleRotation() }
                Toggle("Random order", isOn: $shuffle)
                    .disabled(!rotating)
                LabeledContent("") {
                    Button("Next Wallpaper") { wallpapers.nextWallpaper() }
                        .disabled(!rotating)
                        .accessibilityLabel("Next Wallpaper")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { wallpapers.refresh() }
    }
}

// MARK: Screen Saver

struct ScreenSaverTab: View {
    @EnvironmentObject private var wallpapers: Wallpapers
    @State private var idle = SystemSettings.idleTime

    private var idleOptions: [(Int, String)] {
        var list: [(Int, String)] = [
            (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes"),
            (1200, "20 minutes"), (1800, "30 minutes"), (3600, "1 hour"), (0, "Never"),
        ]
        if !list.contains(where: { $0.0 == idle }) { list.insert((idle, "\(idle / 60) minutes"), at: 0) }
        return list
    }

    var body: some View {
        Form {
            Section {
                PresetGrid(kind: .idle)
            } header: {
                Text("Your Screen Savers")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    FooterText("Pick one in System Settings, then save it here to switch in one click.")
                    Spacer()
                    SettingsLinkButton(title: "Screen Saver Settings…", pane: "ScreenSaver")
                }
            }

            Section {
                Picker("Start when inactive for", selection: Binding(get: { idle }, set: { idle = $0; wallpapers.idleTime = $0 })) {
                    ForEach(idleOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Preview") {
                    Button("Start Screen Saver") { SystemSettings.startScreenSaver() }
                        .accessibilityLabel("Start Screen Saver")
                }
            }

            Section {
                HotCornersView()
            } header: {
                Text("Hot Corners")
            } footer: {
                FooterText("Move the pointer into a corner to trigger its action. Changing a corner briefly restarts the Dock.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            wallpapers.refresh()
            idle = SystemSettings.idleTime
        }
    }
}

/// The classic macOS layout: a screen with one action picker beside each corner.
private struct HotCornersView: View {
    @EnvironmentObject private var wallpapers: Wallpapers
    @State private var corners: [SystemSettings.Corner: SystemSettings.CornerAction] = [:]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing) { picker(.tl); Spacer(); picker(.bl) }
            EntryThumbnail(summary: wallpapers.desktop)
                .frame(width: 200, height: 125)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.2)))
                .overlay(alignment: .topLeading) { dot(.tl) }
                .overlay(alignment: .topTrailing) { dot(.tr) }
                .overlay(alignment: .bottomLeading) { dot(.bl) }
                .overlay(alignment: .bottomTrailing) { dot(.br) }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading) { picker(.tr); Spacer(); picker(.br) }
        }
        .frame(height: 137)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            corners = Dictionary(uniqueKeysWithValues: SystemSettings.Corner.allCases.map { ($0, SystemSettings.hotCorner($0)) })
        }
    }

    private func picker(_ corner: SystemSettings.Corner) -> some View {
        Picker(corner.title, selection: Binding(
            get: { corners[corner] ?? .none },
            set: { corners[corner] = $0; SystemSettings.setHotCorner(corner, to: $0) }
        )) {
            ForEach(SystemSettings.CornerAction.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("\(corner.title) hot corner")
    }

    @ViewBuilder
    private func dot(_ corner: SystemSettings.Corner) -> some View {
        if (corners[corner] ?? .none) != .none {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(5)
        }
    }
}
