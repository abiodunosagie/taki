import Foundation
import UserNotifications

/// Quiet, one-time alerts: a server left running a long time, or a Claude limit nearly used.
/// Each alert fires once per key (per server start, per limit window) and never repeats.
@MainActor
final class Notifier {
    static let shared = Notifier()
    private var sent = Set<String>()

    func requestOnce() {
        guard !Demo.isOn else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(model: AppModel) {
        guard !Demo.isOn else { return }
        let d = UserDefaults.standard
        if d.object(forKey: "notifyServers") as? Bool ?? true {
            for ws in model.workspaces {
                for s in ws.services {
                    guard let r = model.runner.running[s.id], Date().timeIntervalSince(r.startedAt) > 2 * 3600 else { continue }
                    post(key: "server-\(s.id)-\(r.startedAt.timeIntervalSince1970)",
                         title: "\(ws.name) is still running",
                         body: "\(s.name) has been up for over 2 hours. Stop it from Taki if you are done.")
                }
            }
        }
        if d.object(forKey: "notifyLimits") as? Bool ?? true, let l = model.limits {
            if let u = l.fiveHourUsed, u >= 0.9, let reset = l.fiveHourResets {
                post(key: "five-\(reset.timeIntervalSince1970)", title: "Claude 5-hour limit at \(Int(u * 100))%",
                     body: "It resets at \(Format.clock(reset)).")
            }
            if let u = l.weekUsed, u >= 0.9, let reset = l.weekResets {
                post(key: "week-\(reset.timeIntervalSince1970)", title: "Claude weekly limit at \(Int(u * 100))%",
                     body: "It resets \(reset.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
    }

    private func post(key: String, title: String, body: String) {
        guard !sent.contains(key) else { return }
        sent.insert(key)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: c, trigger: nil))
    }
}
