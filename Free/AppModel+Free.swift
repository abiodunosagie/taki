import Foundation

extension AppModel {
    /// Demo mode: shows the sample data instead of the Mac's own (for screenshots).
    func apply(_ d: Demo.Snapshot) {
        agents = d.agents
        servers = d.servers
        externalServers = d.servers
        unclaimedServers = d.servers
        usage = d.usage
        usageReady = true
        system = d.system
        limits = d.limits
    }

    /// A new terminal opens in the folder of the tab in front, else the home folder.
    var defaultFolder: String { terminals.last?.folder ?? NSHomeDirectory() }
}
