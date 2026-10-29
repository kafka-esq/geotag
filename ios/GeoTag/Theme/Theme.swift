import SwiftUI
import UIKit

/// The whole look: night-time brick, chalk white, hot pink paint, caution yellow.
enum Theme {
    static let ink = Color(hex: 0x0E0C10)
    static let chalk = Color(hex: 0xF3EFE6)
    static let paint = Color(hex: 0xFF3D7F)
    static let cap = Color(hex: 0xFFD23F)
    static let go = Color(hex: 0x8CFF5A)
    static let mute = Color(hex: 0xA49EA9)
    static let panel = Color(hex: 0x100D12).opacity(0.86)
    static let sheet = Color(hex: 0x151218)
    static let line = Color(hex: 0xF3EFE6).opacity(0.18)

    /// Spray paint colours. Index order is stable because pieces store colours by value, not index.
    static let paints: [String] = [
        "#FF3D7F", "#FFD23F", "#3DC9FF", "#8CFF5A", "#F3EFE6", "#111111",
        "#FF7A1A", "#9B5CFF", "#E8322C", "#1C6BFF", "#00B37A", "#8A8F98",
    ]

    static func display(_ size: CGFloat) -> Font { .custom("SedgwickAveDisplay-Regular", size: size) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    init(css: String) {
        self.init(hex: RGBA8(css: css).hex)
    }
}

/// An sRGB colour as bytes. Pieces store colours as "#RRGGBB" strings.
struct RGBA8: Equatable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(css: String) {
        var s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0xFF3D7F
        r = UInt8((v >> 16) & 0xFF); g = UInt8((v >> 8) & 0xFF); b = UInt8(v & 0xFF); a = 255
    }

    var hex: UInt32 { (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b) }
    var css: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// Small shared bits of styling.
struct Pill: ViewModifier {
    var fill: Color = Theme.panel
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    func pill(_ fill: Color = Theme.panel) -> some View { modifier(Pill(fill: fill)) }
}

struct ChalkButton: ButtonStyle {
    var fill: Color = Theme.panel
    var fg: Color = Theme.chalk
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(16, .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct GraffitiTitle: View {
    var text = "geo#"
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Text(text).font(Theme.display(size)).foregroundStyle(.black).offset(x: size * 0.07, y: size * 0.07)
            Text(text).font(Theme.display(size)).foregroundStyle(Theme.paint).offset(x: size * 0.035, y: size * 0.035)
            Text(text).font(Theme.display(size)).foregroundStyle(Theme.chalk)
        }
        .rotationEffect(.degrees(-5))
        .accessibilityLabel("geo hash")
    }
}

enum Fmt {
    static func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        if s < 86400 * 30 { return "\(Int(s / 86400))d ago" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func metres(_ m: Double) -> String {
        m < 1000 ? "\(Int(m.rounded())) m" : String(format: "%.1f km", m / 1000)
    }
}
