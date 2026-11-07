import AppKit
import SwiftUI

/// Semantic colors follow the window's appearance, including live system theme changes.
enum DockTheme {
    private static func color(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let accent = color("DockAccent", light: 0x5C52D9, dark: 0xB0A5FF)
    static let canvas = color("DockCanvas", light: 0xFAFAFC, dark: 0x191A20)
    static let sidebar = color("DockSidebar", light: 0xF3F3F8, dark: 0x202129)
    static let surface = color("DockSurface", light: 0xFFFFFF, dark: 0x252730)
    static let border = color("DockBorder", light: 0xE7E7EF, dark: 0x363844)
    static let selection = color("DockSelection", light: 0xEEECFC, dark: 0x363148)
    static let success = color("DockSuccess", light: 0x27825E, dark: 0x80CFAD)
    static let warning = color("DockWarning", light: 0xAF721C, dark: 0xE6B77B)
    static let error = color("DockError", light: 0xE52222, dark: 0xFF3030)
}

struct DockActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DockTheme.accent)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(DockTheme.selection, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DockTheme.accent.opacity(configuration.isPressed ? 0.5 : 0.12)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
