import AppKit
import SwiftUI

enum LockStyle: String, CaseIterable, Identifiable {
    case black, color, image
    var id: Self { self }
    var title: String {
        switch self {
        case .black: "Black"
        case .color: "Solid Color"
        case .image: "Image"
        }
    }
}

enum Scaling: String, CaseIterable, Identifiable {
    case fill, fit, stretch, center
    var id: Self { self }
    var title: String {
        switch self {
        case .fill: "Fill Screen"
        case .fit: "Fit to Screen"
        case .stretch: "Stretch to Fill Screen"
        case .center: "Center"
        }
    }
    var usesBackground: Bool { self == .fit || self == .center }

    func options(background: NSColor) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        switch self {
        case .fill: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
        case .fit: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: false, .fillColor: background]
        case .stretch: [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true]
        case .center: [.imageScaling: NSImageScaling.scaleNone.rawValue, .allowClipping: false, .fillColor: background]
        }
    }
}

enum Keys {
    static let enabled = "enabled"
    static let style = "style"
    static let colorHex = "colorHex"
    static let imagePath = "imagePath"
    static let imageName = "imageName"
    static let scaling = "scaling"
    static let backgroundHex = "backgroundHex"
    static let restoreDelay = "restoreDelay"
    static let maxRetries = "maxRetries"
    static let desktopScaling = "desktopScaling"
    static let desktopBackgroundHex = "desktopBackgroundHex"
    static let desktopColorHex = "desktopColorHex"
    static let desktopImagePath = "desktopImagePath"
    static let rotationEnabled = "rotationEnabled"
    static let rotationFolder = "rotationFolder"
    static let rotationInterval = "rotationInterval"
    static let rotationShuffle = "rotationShuffle"
    static let rotationLast = "rotationLast"
    static let rotationCurrent = "rotationCurrent"
    static let recents = "recents"
    static let showInMenuBar = "showInMenuBar"
    static let hasOnboarded = "hasOnboarded"
    static let settingsPane = "settingsPane"
}

/// Non-view access to the same UserDefaults keys the views bind with @AppStorage.
enum Prefs {
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            Keys.enabled: true, Keys.style: LockStyle.black.rawValue, Keys.colorHex: "1C1C1E",
            Keys.scaling: Scaling.fill.rawValue, Keys.backgroundHex: "000000",
            Keys.restoreDelay: 2.0, Keys.maxRetries: 4,
            Keys.desktopScaling: Scaling.fill.rawValue,
            Keys.desktopBackgroundHex: "000000", Keys.desktopColorHex: "1C1C1E",
            Keys.rotationInterval: 1800, Keys.rotationShuffle: true, Keys.showInMenuBar: true,
        ])
    }

    static var desktopScaling: Scaling { Scaling(rawValue: d.string(forKey: Keys.desktopScaling) ?? "") ?? .fill }
    static var desktopBackgroundHex: String { d.string(forKey: Keys.desktopBackgroundHex) ?? "000000" }
    static var desktopImagePath: String {
        get { d.string(forKey: Keys.desktopImagePath) ?? "" }
        set { d.set(newValue, forKey: Keys.desktopImagePath) }
    }
    static var rotationEnabled: Bool {
        get { d.bool(forKey: Keys.rotationEnabled) }
        set { d.set(newValue, forKey: Keys.rotationEnabled) }
    }
    static var rotationFolder: String { d.string(forKey: Keys.rotationFolder) ?? "" }
    static var rotationInterval: Int { max(60, d.integer(forKey: Keys.rotationInterval)) }
    static var rotationShuffle: Bool { d.bool(forKey: Keys.rotationShuffle) }
    static var rotationLast: Double {
        get { d.double(forKey: Keys.rotationLast) }
        set { d.set(newValue, forKey: Keys.rotationLast) }
    }
    static var rotationCurrent: String {
        get { d.string(forKey: Keys.rotationCurrent) ?? "" }
        set { d.set(newValue, forKey: Keys.rotationCurrent) }
    }

    static var enabled: Bool { d.bool(forKey: Keys.enabled) }
    static var style: LockStyle {
        get { LockStyle(rawValue: d.string(forKey: Keys.style) ?? "") ?? .black }
        set { d.set(newValue.rawValue, forKey: Keys.style) }
    }
    static var colorHex: String { d.string(forKey: Keys.colorHex) ?? "000000" }
    static var backgroundHex: String { d.string(forKey: Keys.backgroundHex) ?? "000000" }
    static var scaling: Scaling { Scaling(rawValue: d.string(forKey: Keys.scaling) ?? "") ?? .fill }
    static var imagePath: String {
        get { d.string(forKey: Keys.imagePath) ?? "" }
        set { d.set(newValue, forKey: Keys.imagePath) }
    }
    static var imageName: String {
        get { d.string(forKey: Keys.imageName) ?? "" }
        set { d.set(newValue, forKey: Keys.imageName) }
    }
    static var restoreDelay: Double { max(0.5, d.double(forKey: Keys.restoreDelay)) }
    static var maxRetries: Int { max(1, d.integer(forKey: Keys.maxRetries)) }
}

extension NSColor {
    convenience init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "000000" }
        func b(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }
}

extension Binding where Value == String {
    /// Bridges a stored hex string to a ColorPicker.
    var asColor: Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: NSColor(hex: wrappedValue) ?? .black) },
            set: { wrappedValue = NSColor($0).hexString }
        )
    }
}
