import Darwin
import Foundation

/// Mac-wide memory and the apps using the most of it, for the "Apps and system" card.
struct SystemSnapshot: Equatable, Sendable {
    struct App: Equatable, Sendable, Identifiable {
        var id: String { name }
        let name: String
        let memory: UInt64
    }
    var usedMemory: UInt64 = 0
    var totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    var apps: [App] = []
}

enum SystemScanner {
    static func scan() -> SystemSnapshot {
        var snap = SystemSnapshot()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if r == KERN_SUCCESS {
            let page = UInt64(getpagesize())
            // "Memory used" as Activity Monitor counts it: app memory + wired + compressed.
            let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            snap.usedMemory = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        }
        // Group processes by the .app they belong to (helpers count toward their app).
        let parents = ProcessScanner.parentMap()
        var byApp: [String: UInt64] = [:]
        for pid in parents.keys {
            let path = ProcessScanner.path(of: pid)
            guard let r = path.range(of: ".app/") else { continue }
            let name = (String(path[..<r.lowerBound]) as NSString).lastPathComponent
            byApp[name, default: 0] += ProcessScanner.memory(of: pid)
        }
        snap.apps = byApp.map { SystemSnapshot.App(name: $0.key, memory: $0.value) }
            .sorted { $0.memory > $1.memory }.prefix(6).map { $0 }
        return snap
    }
}
