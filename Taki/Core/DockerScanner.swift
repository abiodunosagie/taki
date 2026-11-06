import Foundation

/// A running Docker container with its published ports.
struct DockerContainer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let image: String
    let ports: [Int]          // host ports published to this Mac
    let status: String        // "Up 2 days (healthy)"
    let project: String?      // docker compose project name
    let workingDir: String?   // compose project folder

    var healthy: Bool { !status.contains("unhealthy") }
    /// The container name without its compose project prefix and replica number
    /// ("supoclip-redis-1" -> "redis", "supoclip-redis-12" stays "redis-12").
    var shortName: String {
        guard let project, name.hasPrefix(project) else { return name }
        var rest = String(name.dropFirst(project.count).drop { $0 == "-" || $0 == "_" })
        if rest.hasSuffix("-1") || rest.hasSuffix("_1") { rest.removeLast(2) }
        return rest.isEmpty ? name : rest
    }
}

/// Reads `docker ps` (the Docker CLI, when Docker is running). Nothing is started or changed.
enum DockerScanner {
    /// Where Docker Desktop and Homebrew install the CLI. These come before the login PATH so a
    /// stray `docker` earlier on the PATH is not the one Taki runs every few seconds.
    static let knownPaths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                             "/Applications/Docker.app/Contents/Resources/bin/docker"]

    /// A daemon that is starting or hung can block `docker ps`; it is stopped after this long.
    static let timeout: TimeInterval = 4

    /// The running containers, or nil when Docker is not installed, not running or did not answer.
    static func scan() -> [DockerContainer]? {
        guard let docker = knownPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                ?? ShellEnvironment.which("docker"),
              let d = ShellEnvironment.run(docker, ["ps", "--no-trunc", "--format", "{{json .}}"], timeout: timeout)
        else { return nil }
        var out: [DockerContainer] = []
        for line in d.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let labels = parseLabels(o["Labels"] as? String ?? "")
            out.append(DockerContainer(id: o["ID"] as? String ?? UUID().uuidString, name: o["Names"] as? String ?? "container",
                                       image: o["Image"] as? String ?? "", ports: hostPorts(o["Ports"] as? String ?? ""),
                                       status: o["Status"] as? String ?? "", project: labels["com.docker.compose.project"],
                                       workingDir: labels["com.docker.compose.project.working_dir"]))
        }
        return out.sorted { ($0.project ?? $0.name, $0.name) < ($1.project ?? $1.name, $1.name) }
    }

    /// "a=1,b=x,y" -> ["a": "1", "b": "x,y"]: a piece with no "=" belongs to the value before it
    /// (a compose folder path can hold a comma).
    static func parseLabels(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var lastKey: String?
        for piece in s.split(separator: ",", omittingEmptySubsequences: false) {
            let kv = piece.split(separator: "=", maxSplits: 1)
            if kv.count == 2, !kv[0].contains(" ") {
                lastKey = String(kv[0])
                out[String(kv[0])] = String(kv[1])
            } else if let key = lastKey {
                out[key, default: ""] += "," + piece
            }
        }
        return out
    }

    /// "0.0.0.0:5434->5432/tcp, [::]:5434->5432/tcp, 8000/tcp" -> [5434] (only ports published to
    /// the host). A range "0.0.0.0:3000-3002->3000-3002/tcp" gives 3000, 3001 and 3002.
    static func hostPorts(_ s: String) -> [Int] {
        var ports: [Int] = []
        for part in s.split(separator: ",") where part.contains("->") {
            let host = part.components(separatedBy: "->").first ?? ""
            guard let spec = host.split(separator: ":").last else { continue }
            let bounds = spec.split(separator: "-").compactMap { Int($0) }
            guard let low = bounds.first else { continue }
            let high = bounds.count == 2 ? min(bounds[1], low + 64) : low      // a huge range is not listed port by port
            for p in low...max(low, high) where !ports.contains(p) { ports.append(p) }
        }
        return ports
    }
}
