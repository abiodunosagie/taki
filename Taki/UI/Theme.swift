import AppKit
import SwiftUI

/// Visual language: a slate window, a floating lighter sidebar panel,
/// flat tiles slightly lighter than the window (no glass, no borders), plain SF Pro with large
/// medium-weight numbers, gray units and captions, soft blue links, one accent per meaning.
/// Every color has a light and a dark value.
enum Theme {
    static let radius: CGFloat = 18
    static let gutter: CGFloat = 12

    // Accents
    static let live = Color(light: 0x23A047, dark: 0x5AD16D)
    static let busy = Color(light: 0xD98200, dark: 0xF5A623)
    static let link = Color(light: 0x2F6BE0, dark: 0x82A9FF)
    static let danger = Color(light: 0xD93D3D, dark: 0xFF8A80)
    static let claude = Color(light: 0xD9663A, dark: 0xF07B4B)
    static let codexBlue = Color(light: 0x3D7BF0, dark: 0x5B8DF6)

    // Surfaces
    static let windowTop = Color(light: 0xECEDEF, dark: 0x3C4045)
    static let windowBottom = Color(light: 0xE2E4E7, dark: 0x2B2E32)
    static let sidebarTop = Color(light: 0xF7F7F8, dark: 0x4B4E53)
    static let sidebarBottom = Color(light: 0xEEEFF1, dark: 0x36393D)
    static let tileTop = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.92, darkAlpha: 0.095)
    static let tileBottom = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.70, darkAlpha: 0.055)
    static let tileRaised = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.09)
    static let field = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.06, darkAlpha: 0.28)
    static let inset = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.045, darkAlpha: 0.30)
    static let selection = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.12)
    static let tileSelected = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 1.0, darkAlpha: 0.14)
    static let glyph = Color(light: 0x1C1D1F, dark: 0x1C1D1F)

    // Text
    static let primary = Color(light: 0x1D1E20, dark: 0xF2F3F5)
    static let secondary = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.52, darkAlpha: 0.55)
    static let tertiary = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.32, darkAlpha: 0.34)

    /// The in-app terminal is dark in both appearances, like Terminal's default profile.
    static let terminalNSBackground = NSColor(srgbRed: 0.10, green: 0.105, blue: 0.115, alpha: 1)
    static let terminalBackground = Color(nsColor: terminalNSBackground)

    /// A context share past this is shown in amber (time to compact or start fresh).
    static let contextWarn = 0.6

    /// The dark track under a ring gauge,, a deep blue-gray.
    static let ringTrack = Color(light: 0xD7DCE5, dark: 0x2B3A52)

    static let mono = Font.system(size: 13, design: .monospaced)
    static let label = Font.system(size: 14, weight: .medium)
    static let body = Font.system(size: 15)
}

extension Color {
    /// A color with a light and a dark value, resolved by the view's appearance.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        func ns(_ hex: UInt32, _ a: Double) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark, darkAlpha) : ns(light, lightAlpha)
        })
    }
}

/// A flat tile with an optional title row: the building block of every screen.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var badge: String?
    var fill = true
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String? = nil, badge: String? = nil, fill: Bool = true,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.fill = fill
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || badge != nil {
                HStack(spacing: 6) {
                    if let title { Text(title).font(Theme.label).foregroundStyle(Theme.secondary) }
                    if let badge { Text(badge).font(.system(size: 14)).foregroundStyle(Theme.tertiary) }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .tileSurface()
    }
}

/// The tile surface: a fill that is a touch lighter at the top, a hairline
/// rim that catches light along the top edge and fades down the sides, and a soft shadow under
/// it, so each tile reads as a slightly raised pane rather than a flat rectangle.
struct TileSurface: ViewModifier {
    var radius: CGFloat = Theme.radius
    var raised = false            // the selected tile in the menu panel
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        content
            .background {
                shape.fill(LinearGradient(colors: [raised ? Theme.tileSelected : Theme.tileTop, Theme.tileBottom],
                                          startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(dark ? 0.28 : 0.08), radius: dark ? 7 : 5, y: dark ? 3 : 2)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(stops: [
                    .init(color: .white.opacity(dark ? (raised ? 0.20 : 0.13) : 0.9), location: 0),
                    .init(color: .white.opacity(dark ? 0.04 : 0.4), location: 0.35),
                    .init(color: .black.opacity(dark ? 0.10 : 0.05), location: 1),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }
}

/// The floating sidebar panel: lighter at the top, darker at the bottom, a light rim along its
/// top edge and a soft shadow.
struct SidebarPanel: ViewModifier {
    static let radius: CGFloat = 22
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let dark = scheme == .dark
        content
            .background {
                shape.fill(LinearGradient(colors: [Theme.sidebarTop, Theme.sidebarBottom], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(dark ? 0.30 : 0.10), radius: 10, y: 4)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(stops: [
                    .init(color: .white.opacity(dark ? 0.14 : 0.9), location: 0),
                    .init(color: .white.opacity(dark ? 0.04 : 0.5), location: 0.2),
                    .init(color: .white.opacity(dark ? 0.02 : 0.3), location: 1),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
    }
}

extension View {
    /// The system's Liquid Glass on a pill or round button. Not `.interactive()`: that variant
    /// squashes and stretches the glass under the pointer, which on small round buttons reads as a
    /// stretched oval (owner, 2026-11-07). Pressed feedback comes from the button style instead.
    func glassPill() -> some View { glassEffect(.regular, in: .capsule) }
    func glassCircle() -> some View { glassEffect(.regular, in: .circle) }

    func sidebarPanel() -> some View { modifier(SidebarPanel()) }

    func tileSurface(radius: CGFloat = Theme.radius, raised: Bool = false) -> some View {
        modifier(TileSurface(radius: radius, raised: raised))
    }
}

/// A big number with a gray unit and a caption, as on the Uptime / CPU / Memory cards.
struct StatNumber: View {
    let value: String
    var unit: String = ""
    var caption: String = ""
    var captionColor: Color = Theme.secondary
    var size: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: size, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.primary).lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.system(size: size * 0.5)).foregroundStyle(Theme.secondary) }
            }
            if !caption.isEmpty {
                Text(caption).font(.system(size: 14)).foregroundStyle(captionColor).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
    }
}

/// Thin vertical bars; the last one carries the accent.
struct Sparkline: View {
    let values: [Double]
    var highlight: Color = Theme.link
    var height: CGFloat = 20
    var barWidth: CGFloat = 3

    var body: some View {
        let maxV = max(values.max() ?? 1, 0.0001)
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                Capsule()
                    .fill(i == values.count - 1 ? highlight : Theme.tertiary)
                    .frame(width: barWidth, height: max(3, CGFloat(v / maxV) * height))
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

/// A thin progress bar for context use.
struct ThinBar: View {
    let value: Double
    var color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.selection)
                Capsule().fill(color).frame(width: max(4, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4)
    }
}

/// Ring gauge used for plan limits.
struct Ring<Inner: View>: View {
    let value: Double?
    var color: Color
    var size: CGFloat = 54
    var track: Color = Theme.selection
    @ViewBuilder var inner: Inner

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 4)
            Circle().trim(from: 0, to: min(1, value ?? 0))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            inner
        }
        .frame(width: size, height: size)
    }
}

/// Half-ring gauge of this hour's average power (full at `EnergyLevel.gaugeFullWatts`).
struct EnergyGauge: View {
    let value: Double
    var color: Color

    var body: some View {
        ZStack {
            Circle().trim(from: 0.5, to: 1).stroke(Theme.selection, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            Circle().trim(from: 0.5, to: 0.5 + 0.5 * max(0.03, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        .frame(width: 52, height: 52)
        .offset(y: 13)
        .frame(width: 52, height: 30, alignment: .top)
    }
}

enum EnergyLevel {
    static let gaugeFullWatts = 20.0
    static func label(_ w: Double) -> String { w < 5 ? "Low" : w < 15 ? "Moderate" : "High" }
    static func color(_ w: Double) -> Color { w < 5 ? Theme.live : w < 15 ? Theme.busy : Theme.danger }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

/// Brand colors for the framework marks. Black marks are drawn white on the dark tile.
enum Brand {
    static let colors: [String: UInt32] = [
        "nextdotjs": 0xFFFFFF, "vite": 0xA78BFF, "react": 0x61DAFB, "nodedotjs": 0x6CC24A, "go": 0x00ADD8,
        "flutter": 0x45D1FD, "python": 0x4B8BBE, "swift": 0xF05138, "nestjs": 0xE0234E, "expo": 0xFFFFFF,
        "astro": 0xBC52EE, "express": 0xFFFFFF, "storybook": 0xFF4785, "svelte": 0xFF3E00, "remix": 0xFFFFFF,
        "docker": 0x2496ED, "postgresql": 0x6B9BE1, "redis": 0xFF4438, "laravel": 0xFF2D20, "django": 0x44B78B,
        "fastapi": 0x05998B, "rust": 0xFFFFFF, "typescript": 0x3178C6, "vuedotjs": 0x4FC08D, "angular": 0xDD0031,
        "deno": 0xFFFFFF, "bun": 0xFBF0DF, "supabase": 0x3FCF8E,
    ]

    /// The mark for a Docker image name (postgres, redis, ...), if there is one.
    static func logo(forImage image: String) -> String? {
        let i = image.lowercased()
        for (key, logo) in [("postgres", "postgresql"), ("postgis", "postgresql"), ("redis", "redis"), ("node", "nodedotjs"),
                            ("python", "python"), ("supabase", "supabase"), ("nginx", "docker")] where i.contains(key) {
            return logo
        }
        return nil
    }
}

/// Square app-icon badge for a workspace: the framework's own mark on a dark tile, else an SF
/// Symbol, else the first letter.
struct WorkspaceBadge: View {
    let symbol: String
    let name: String
    var logo: String? = nil
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(Theme.glyph)
            if let logo, NSImage(named: "logo-" + logo) != nil {
                Image("logo-" + logo).renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(Color(light: Brand.colors[logo] ?? 0xFFFFFF, dark: Brand.colors[logo] ?? 0xFFFFFF))
                    .padding(size * 0.2)
            } else if symbol == "folder" || symbol.isEmpty {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The agent's mark on a dark tile: Claude's starburst, a terminal for Codex, Cursor's cube.
/// `framed` adds a soft glass ring around it, for the menu bar tree.
struct AgentGlyph: View {
    let tool: LiveAgent.Tool
    var size: CGFloat = 34
    var framed = false

    var body: some View {
        let tile = mark
            .frame(width: size * 0.5, height: size * 0.5)
            .frame(width: size, height: size)
            .background(Theme.glyph, in: .rect(cornerRadius: size * 0.26, style: .continuous))
        if framed {
            tile.padding(3).glassEffect(.regular, in: .rect(cornerRadius: size * 0.26 + 3, style: .continuous))
        } else {
            tile
        }
    }

    @ViewBuilder private var mark: some View {
        switch tool {
        case .claude: Image("logo-claude").resizable().scaledToFit().foregroundStyle(Theme.claude)
        case .codex: Image(systemName: "apple.terminal.fill").resizable().scaledToFit().foregroundStyle(.white)
        case .cursor: Image("logo-cursor").resizable().scaledToFit().foregroundStyle(.white)
        }
    }
}

/// A plain text button in the link color ("+ Add", "Change...", "Open").
struct LinkButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 14)).foregroundStyle(Theme.link) }
            .buttonStyle(.plain)
    }
}

/// A capsule button like "Open in Cursor".
struct PillButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.primary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .glassPill()
        }
        .buttonStyle(.plain)
    }
}

/// A dark rounded field for names, links and inputs.
struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.field, in: .rect(cornerRadius: 9, style: .continuous))
    }
}

enum Format {
    static func bytes(_ b: UInt64) -> (String, String) {
        let mb = Double(b) / 1_048_576
        if mb >= 1024 { return (String(format: "%.1f", mb / 1024), "GB") }
        if b > 0 && mb < 1 { return (String(format: "%.0f", max(1, Double(b) / 1024)), "KB") }
        return (String(format: "%.0f", mb), "MB")
    }

    static func bytesText(_ b: UInt64) -> String { let (v, u) = bytes(b); return "\(v) \(u)" }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    static func elapsed(since d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86_400)d"
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    nonisolated(unsafe) private static let logTime: DateFormatter = {   // read-only after init
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")     // fixed 24-hour clock, whatever the region
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func logClock(_ d: Date) -> String { logTime.string(from: d) }
}

/// One folder picker for every "choose a folder" action.
@MainActor
enum FolderPicker {
    static func choose(prompt: String, message: String = "", start: String? = nil, multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        panel.message = message
        if let start { panel.directoryURL = URL(fileURLWithPath: start) }
        return panel.runModal() == .OK ? panel.urls : []
    }
}

extension View {
    /// The inset every main screen uses inside the window, beside the sidebar.
    func screenPadding() -> some View {
        padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 14)
    }
}
