import SwiftUI

/// Colours from design B, for dark and light appearance. Each colour resolves against the
/// panel's appearance (Settings › General › Appearance).
enum Theme {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func white(_ w: CGFloat, _ a: CGFloat) -> NSColor { NSColor(white: w, alpha: a) }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let panel = dynamic(dark: rgb(0.118, 0.118, 0.125, 0.78), light: rgb(0.975, 0.975, 0.98, 0.82))
    static let panelStroke = dynamic(dark: white(1, 0.10), light: white(0, 0.10))
    static let sidebar = dynamic(dark: white(0, 0.14), light: white(0, 0.03))
    static let footer = dynamic(dark: white(0, 0.20), light: white(0, 0.035))
    static let divider = dynamic(dark: white(1, 0.08), light: white(0, 0.08))
    static let rowSelected = dynamic(dark: white(1, 0.11), light: white(0, 0.075))
    static let rowSelectedInactive = dynamic(dark: white(1, 0.05), light: white(0, 0.035))
    static let accentFill = dynamic(dark: rgb(0.184, 0.227, 0.322), light: rgb(0.86, 0.89, 0.96))
    static let accentFillFocused = dynamic(dark: rgb(0.235, 0.361, 0.659), light: rgb(0.74, 0.81, 0.97))
    /// Check marks and outlines of select mode: the sidebar's blue, bright enough for a symbol.
    static let selectTint = dynamic(dark: rgb(0.478, 0.612, 0.937), light: rgb(0.204, 0.373, 0.784))
    static let accentText = dynamic(dark: rgb(0.863, 0.902, 1.0), light: rgb(0.10, 0.22, 0.52))
    static let text = dynamic(dark: rgb(0.925, 0.925, 0.933), light: rgb(0.11, 0.11, 0.12))
    static let muted = dynamic(dark: rgb(0.631, 0.631, 0.659), light: rgb(0.40, 0.40, 0.43))
    static let faint = dynamic(dark: rgb(0.541, 0.541, 0.565), light: rgb(0.50, 0.50, 0.53))
    static let iconFill = dynamic(dark: white(1, 0.07), light: white(0, 0.05))
    static let kbdFill = dynamic(dark: white(1, 0.10), light: white(0, 0.07))
    static let kbdText = dynamic(dark: rgb(0.706, 0.706, 0.729), light: rgb(0.38, 0.38, 0.41))
    static let destructive = Color(red: 0.898, green: 0.329, blue: 0.329)
    static let dialog = dynamic(dark: rgb(0.165, 0.165, 0.176), light: rgb(0.985, 0.985, 0.99))
}

struct Kbd: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.kbdText)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Theme.kbdFill, in: RoundedRectangle(cornerRadius: 5))
    }
}
