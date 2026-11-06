import Foundation
import Observation

/// CPU, memory and energy per workspace, from libproc samples of the processes Taki started
/// (and their children). CPU % is the CPU-time delta over the wall-clock delta, of one core.
@MainActor
@Observable
final class ResourceMonitor {
    struct Stats: Equatable {
        var cpu = 0.0                 // percent of one core
        var cpuPeak = 0.0
        var memory: UInt64 = 0
        var watts: Double?            // nil when the kernel reports no energy
        var cpuHistory: [Double] = []      // one sample per poll (3 s), the last 5 minutes
        var memHistory: [Double] = []
        var wattsThisHour: [Double] = []   // samples since the top of the hour, for the average
        var hourStart = Date.distantPast

        var wattsAverage: Double? { wattsThisHour.isEmpty ? nil : wattsThisHour.reduce(0, +) / Double(wattsThisHour.count) }
    }

    private(set) var stats: [UUID: Stats] = [:]

    /// Demo mode only: sample figures for the stat tiles.
    func showDemo(_ stats: [UUID: Stats]) { self.stats = stats }
    @ObservationIgnored private var last: [Int32: (cpu: UInt64, energy: UInt64, at: Date)] = [:]
    static let historyLength = 100      // 5 minutes at one sample every 3 s

    func sample(workspaces: [Workspace], runner: ServiceRunner, servers: [ListeningServer], parents: [Int32: Int32]) {
        let now = Date()
        var seen = Set<Int32>()
        var sampled: [Int32: (cpuNs: UInt64, energyNj: UInt64)] = [:]   // one reading per pid per sample
        let previous = last
        var next: [Int32: (cpu: UInt64, energy: UInt64, at: Date)] = [:]
        for ws in workspaces {
            let roots = ws.services.compactMap { runner.running[$0.id]?.pid }
            var pids = Set<Int32>()
            for r in roots { pids.insert(r); pids.formUnion(ProcessScanner.descendants(of: r, parents: parents)) }
            // Servers already running in the workspace folder count too (started outside Taki).
            for s in servers where ws.contains(path: s.cwd) { pids.insert(s.pid) }
            var cpu = 0.0, watts = 0.0, mem: UInt64 = 0, energyKnown = false
            for pid in pids {
                seen.insert(pid)
                mem += ProcessScanner.memory(of: pid)
                let cur = sampled[pid] ?? ProcessScanner.cpuAndEnergy(of: pid)
                sampled[pid] = cur
                if let prev = previous[pid] {      // the reading before THIS sample, shared by every workspace
                    let dt = now.timeIntervalSince(prev.at)
                    if dt > 0 {
                        cpu += Double(cur.cpuNs &- prev.cpu) / 1e9 / dt * 100
                        if cur.energyNj > 0 {
                            energyKnown = true
                            watts += Double(cur.energyNj &- prev.energy) / 1e9 / dt
                        }
                    }
                }
                next[pid] = (cur.cpuNs, cur.energyNj, now)
            }
            var s = stats[ws.id] ?? Stats()
            s.cpu = max(0, cpu)
            s.memory = mem
            s.watts = energyKnown ? max(0, watts) : (pids.isEmpty ? 0 : nil)
            s.cpuHistory = Array((s.cpuHistory + [s.cpu]).suffix(Self.historyLength))
            s.memHistory = Array((s.memHistory + [Double(mem)]).suffix(Self.historyLength))
            s.cpuPeak = s.cpuHistory.max() ?? 0
            let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
            if hour != s.hourStart { s.hourStart = hour; s.wattsThisHour = [] }
            if let w = s.watts { s.wattsThisHour.append(w) }
            stats[ws.id] = s
        }
        last = next
    }
}
