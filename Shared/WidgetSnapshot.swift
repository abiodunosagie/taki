import Foundation

/// What the desktop widgets show. The app writes it to the shared app-group container on every
/// refresh; the widget extension (sandboxed) only reads it. Numbers only, no secrets or paths
/// beyond folder names.
struct WidgetSnapshot: Codable, Equatable {
    struct Server: Codable, Equatable { var name: String; var port: Int; var memoryMB: Int }
    struct Agent: Codable, Equatable { var task: String; var tool: String; var status: String; var minutes: Int }
    struct Space: Codable, Equatable { var name: String; var running: Bool; var memoryMB: Int; var agents: Int }

    var updated = Date()
    var servers: [Server] = []
    var agents: [Agent] = []
    var workspaces: [Space] = []
    var tokensToday = 0
    var sessionsPerHour: [Int] = []
    var claudeFiveHour: Double?
    var claudeWeek: Double?
    var claudeFiveHourResets: Date?
    var codexWeek: Double?

    /// The app group the app and the widget share, set once in project.yml (TAKI_APP_GROUP).
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "TakiAppGroup") as? String ?? ""

    static var url: URL? {
        guard !appGroup.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        guard let url = Self.url else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(self) { try? d.write(to: url, options: .atomic) }
    }
}
