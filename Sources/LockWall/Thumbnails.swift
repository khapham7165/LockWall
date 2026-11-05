import AppKit
import ImageIO
import SwiftUI

/// Downsampled image thumbnails, cached by path.
@MainActor
enum Thumbnails {
    private static var cache: [String: NSImage] = [:]

    static func image(_ path: String, maxPixels: Int = 480) -> NSImage? {
        let key = "\(path)#\(maxPixels)"
        if let hit = cache[key] { return hit }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache[key] = img
        return img
    }

    /// Approximate Apple system wallpaper colors (macOS renders them live; no hex is stored).
    static func appleColor(_ name: String) -> (top: Color, bottom: Color) {
        let table: [String: (String, String)] = [
            "gold": ("D9B77E", "8C6A3A"), "yellow": ("F2D25C", "B08A1C"), "orange": ("F29B4B", "A9561C"),
            "red": ("E8615A", "9A2A26"), "pink": ("EE8FB4", "A84C74"), "purple": ("B48BE0", "6A3FA0"),
            "blue": ("6FA8F0", "2C5FA8"), "teal": ("5BC2C2", "1F7A7E"), "green": ("7CCB7A", "347A3A"),
            "silver": ("C9CCD1", "8A8E96"), "gray": ("9A9DA3", "4B4E54"), "graphite": ("7D8087", "35373C"),
            "spacegray": ("6E7076", "2B2C30"), "stone": ("C2B8A8", "7D7364"),
        ]
        let pair = table[name.lowercased()] ?? ("9A9DA3", "4B4E54")
        return (Color(nsColor: NSColor(hex: pair.0)!), Color(nsColor: NSColor(hex: pair.1)!))
    }

    /// Small rounded swatch for menu items.
    static func menuIcon(_ preview: WallpaperStore.Summary.Preview, symbol: String) -> NSImage {
        let size = NSSize(width: 26, height: 17)
        let thumb: NSImage? = if case .image(let path) = preview { image(path, maxPixels: 120) } else { nil }
        let colors: (NSColor, NSColor)? = switch preview {
        case .color(let hex): (NSColor(hex: hex) ?? .black, NSColor(hex: hex) ?? .black)
        case .appleColor(let name): (NSColor(appleColor(name).top), NSColor(appleColor(name).bottom))
        default: nil
        }
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            path.addClip()
            if let thumb {
                let s = thumb.size, k = max(rect.width / s.width, rect.height / s.height)
                let w = s.width * k, h = s.height * k
                thumb.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            } else if let colors {
                NSGradient(starting: colors.0, ending: colors.1)?.draw(in: rect, angle: -90)
            } else {
                NSColor.tertiaryLabelColor.setFill(); rect.fill()
                if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .medium).applying(.init(paletteColors: [.white]))) {
                    let s = sym.size
                    sym.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
                }
            }
            NSColor.black.withAlphaComponent(0.2).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}

/// Fills its frame with what a wallpaper or screen saver entry looks like (best effort).
struct EntryThumbnail: View {
    let summary: WallpaperStore.Summary

    var body: some View {
        switch summary.preview {
        case .image(let path):
            if let img = Thumbnails.image(path) {
                Color.clear.overlay(Image(nsImage: img).resizable().scaledToFill()).clipped()
            } else {
                symbolTile
            }
        case .color(let hex):
            Color(nsColor: NSColor(hex: hex) ?? .black)
        case .appleColor(let name):
            let c = Thumbnails.appleColor(name)
            LinearGradient(colors: [c.top, c.bottom], startPoint: .top, endPoint: .bottom)
        case .symbol:
            symbolTile
        }
    }

    private var symbolTile: some View {
        LinearGradient(colors: [Color(white: 0.32), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
            .overlay(Image(systemName: summary.symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.85)))
    }
}

/// A selectable 16:10 thumbnail with a caption, styled after System Settings' wallpaper grid.
struct Tile<Thumb: View>: View {
    let title: String
    var subtitle: String? = nil
    var selected = false
    var busy = false
    let action: () -> Void
    @ViewBuilder let thumb: () -> Thumb
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                thumb()
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.black.opacity(0.12)))
                    .overlay {
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : (hovering ? Color.secondary.opacity(0.35) : .clear),
                                          lineWidth: selected ? 2.5 : 1.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            VStack(spacing: 1) {
                Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Dashed "add" tile that matches Tile's geometry.
struct AddTile<Menu: View>: View {
    let title: String
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        VStack(spacing: 5) {
            SwiftUI.Menu {
                menu()
            } label: {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary))
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityLabel(title)
    }
}
