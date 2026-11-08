import AppKit
import SwiftUI

/// Where each piece of the menu-bar icon is drawn, in points, on a canvas of
/// `size`. Kept separate from the drawing code so a test can assert the one
/// thing that has already gone wrong once: anything drawn outside the canvas
/// -- a badge's cut-out ring included -- is clipped by the menu bar, which
/// showed as the status dot being sliced off at the right and bottom edges.
enum StatusIconGeometry {
    static let size = NSSize(width: 24, height: 18)
    static let bubble = NSRect(x: 0, y: 0, width: 18, height: 18)
    static let bolt = NSRect(x: 5, y: 4, width: 8, height: 10)
    /// Server state, bottom right.
    static let statusDot = NSRect(x: 15.5, y: 1.25, width: 7, height: 7)
    /// "Update available", top right -- its own corner, so it no longer
    /// covers the status dot.
    static let updateDot = NSRect(x: 15.5, y: 9.75, width: 7, height: 7)
    static let ringWidth: CGFloat = 1.25

    /// The transparent ring cut out around a dot so it reads against the bubble.
    static func ring(around dot: NSRect) -> NSRect {
        dot.insetBy(dx: -ringWidth, dy: -ringWidth)
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case catppuccinLatte = "Catppuccin Latte"
    case catppuccinFrappe = "Catppuccin Frappé"
    case catppuccinMacchiato = "Catppuccin Macchiato"
    case catppuccinMocha = "Catppuccin Mocha"
    case nord = "Nord"
    case dracula = "Dracula"
    case solarizedDark = "Solarized Dark"

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light, .catppuccinLatte: .light
        default: .dark
        }
    }
    var accent: Color {
        switch self {
        case .system, .light, .dark: .accentColor
        case .catppuccinLatte: Color(hex: 0x1E66F5)
        case .catppuccinFrappe: Color(hex: 0x8CAAEE)
        case .catppuccinMacchiato: Color(hex: 0x8AADF4)
        case .catppuccinMocha: Color(hex: 0x89B4FA)
        case .nord: Color(hex: 0x88C0D0)
        case .dracula: Color(hex: 0xBD93F9)
        case .solarizedDark: Color(hex: 0x2AA198)
        }
    }
    var background: Color {
        switch self {
        case .catppuccinLatte: Color(hex: 0xEFF1F5)
        case .catppuccinFrappe: Color(hex: 0x303446)
        case .catppuccinMacchiato: Color(hex: 0x24273A)
        case .catppuccinMocha: Color(hex: 0x1E1E2E)
        case .nord: Color(hex: 0x2E3440)
        case .dracula: Color(hex: 0x282A36)
        case .solarizedDark: Color(hex: 0x002B36)
        default: Color(nsColor: .windowBackgroundColor)
        }
    }
    var foreground: Color {
        switch self {
        case .catppuccinLatte: Color(hex: 0x4C4F69)
        case .catppuccinFrappe: Color(hex: 0xC6D0F5)
        case .catppuccinMacchiato: Color(hex: 0xCAD3F5)
        case .catppuccinMocha: Color(hex: 0xCDD6F4)
        case .nord: Color(hex: 0xECEFF4)
        case .dracula: Color(hex: 0xF8F8F2)
        case .solarizedDark: Color(hex: 0xEEE8D5)
        default: .primary
        }
    }
    var surface: Color {
        switch self {
        case .catppuccinLatte: Color(hex: 0xE6E9EF)
        case .catppuccinFrappe: Color(hex: 0x414559)
        case .catppuccinMacchiato: Color(hex: 0x363A4F)
        case .catppuccinMocha: Color(hex: 0x313244)
        case .nord: Color(hex: 0x3B4252)
        case .dracula: Color(hex: 0x44475A)
        case .solarizedDark: Color(hex: 0x073642)
        default: Color(nsColor: .controlBackgroundColor)
        }
    }
    var previewBackground: Color {
        switch self {
        case .system: Color(hex: 0x303033)
        case .light: Color(hex: 0xF2F2F7)
        case .dark: Color(hex: 0x1C1C1E)
        default: background
        }
    }
    var previewSurface: Color {
        switch self {
        case .system: Color(hex: 0x48484A)
        case .light: Color.white
        case .dark: Color(hex: 0x2C2C2E)
        default: surface
        }
    }
    var previewForeground: Color {
        switch self {
        case .system, .dark: Color.white
        case .light: Color(hex: 0x1C1C1E)
        default: foreground
        }
    }
    var nsAccent: NSColor { NSColor(accent) }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case matchSystem = "Match System"
    case colour = "Colour"
    case monochrome = "Monochrome"
    var id: String { rawValue }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

struct ThemedRoot<Content: View>: View {
    @Environment(AppStore.self) private var store
    let content: Content
    var body: some View {
        content
            .preferredColorScheme(store.appTheme.colorScheme)
            .tint(store.appTheme.accent)
            .foregroundStyle(store.appTheme.foreground)
            .scrollContentBackground(.hidden)
            .background(store.appTheme.background.ignoresSafeArea())
    }
}

extension Notification.Name {
    static let inferenceAppearanceChanged = Notification.Name("InferenceBar.appearanceChanged")
}
