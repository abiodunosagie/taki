import Foundation

/// A project folder Taki manages: its services (dev commands), link name and env var names.
/// Values of env vars are in the Keychain, never in this file.
struct Workspace: Identifiable, Codable, Equatable, Sendable {
    struct Service: Identifiable, Codable, Equatable, Sendable {
        var id = UUID()
        var name: String
        var command: String
        var port: Int?
    }

    var id = UUID()
    var name: String
    var folder: String
    var services: [Service] = []
    var envNames: [String] = []
    var startAtLaunch = false
    var linkName: String
    var iconOverride: String? = nil      // SF Symbol name, nil = automatic from the framework
    var auto: Bool? = nil                // found open on the Mac (an agent, server or container), not added by hand
    var lastActive: Date? = nil          // last time something was running in it (auto workspaces)

    var folderURL: URL { URL(fileURLWithPath: folder) }
    var displayFolder: String { (folder as NSString).abbreviatingWithTildeInPath }

    /// True for the workspace folder itself or anything inside it.
    func contains(path: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

    /// Everything the owner can change, without the bookkeeping Taki updates by itself. Two
    /// versions that differ here mean the owner edited the workspace.
    var settings: Workspace {
        var w = self
        w.auto = nil
        w.lastActive = nil
        return w
    }

    /// A folder Taki may turn into a workspace by itself: a real folder inside the home folder (not
    /// the home folder itself), outside hidden folders such as ~/.ssh and outside ~/Library.
    static func isAdoptable(_ folder: String, home: String = NSHomeDirectory()) -> Bool {
        guard folder.hasPrefix(home + "/") else { return false }
        let parts = folder.dropFirst(home.count + 1).split(separator: "/")
        guard let first = parts.first, first != "Library", !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder, isDirectory: &dir) && dir.boolValue
    }
}

/// What a folder is, read from its files (package.json dependencies, manifests), for the icon,
/// the "Next.js 15" subtitle and suggested services.
struct ProjectFacts: Equatable, Sendable {
    var framework: String = ""
    var symbol: String = "folder"
    var logo: String? = nil          // a brand mark from the asset catalog (Simple Icons, CC0)
    var branch: String = ""
    var suggested: [Workspace.Service] = []

    static func read(folder: String) -> ProjectFacts {
        var f = ProjectFacts()
        let fm = FileManager.default
        let url = URL(fileURLWithPath: folder)
        if let head = try? String(contentsOf: url.appending(path: ".git/HEAD"), encoding: .utf8) {
            f.branch = head.hasPrefix("ref: refs/heads/")
                ? String(head.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines)
                : String(head.prefix(7))
        }
        if let data = try? Data(contentsOf: url.appending(path: "package.json")),
           let pkg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let deps = (pkg["dependencies"] as? [String: String] ?? [:])
                .merging(pkg["devDependencies"] as? [String: String] ?? [:]) { a, _ in a }
            func major(_ name: String) -> String {
                guard let v = deps[name] else { return "" }
                let digits = v.drop { !$0.isNumber }.prefix { $0.isNumber }
                return digits.isEmpty ? "" : " \(digits)"
            }
            // First match wins, most specific framework first (a Next.js app also depends on React).
            let order: [(dep: String, name: String, logo: String)] = [
                ("next", "Next.js", "nextdotjs"), ("nuxt", "Nuxt", "vuedotjs"), ("@remix-run/react", "Remix", "remix"),
                ("astro", "Astro", "astro"), ("@sveltejs/kit", "SvelteKit", "svelte"), ("@nestjs/core", "NestJS", "nestjs"),
                ("expo", "Expo", "expo"), ("@angular/core", "Angular", "angular"), ("express", "Express", "express"),
                ("fastify", "Fastify", "nodedotjs"), ("svelte", "Svelte", "svelte"), ("vue", "Vue", "vuedotjs"),
                ("vite", "Vite", "vite"), ("react", "React", "react"), ("storybook", "Storybook", "storybook"),
            ]
            if let hit = order.first(where: { deps[$0.dep] != nil }) {
                f.framework = hit.name + major(hit.dep); f.logo = hit.logo; f.symbol = "shippingbox.fill"
            } else {
                f.framework = "Node"; f.logo = "nodedotjs"; f.symbol = "shippingbox.fill"
            }
            let runner = fm.fileExists(atPath: url.appending(path: "pnpm-lock.yaml").path) ? "pnpm"
                : fm.fileExists(atPath: url.appending(path: "yarn.lock").path) ? "yarn"
                : fm.fileExists(atPath: url.appending(path: "bun.lockb").path) ? "bun" : "npm run"
            let scripts = pkg["scripts"] as? [String: String] ?? [:]
            for key in ["dev", "start:dev", "email", "storybook"] where scripts[key] != nil {
                let cmd = runner == "npm run" ? "npm run \(key)" : "\(runner) \(key)"
                f.suggested.append(.init(name: key == "dev" ? "web" : key, command: cmd))
            }
        } else if fm.fileExists(atPath: url.appending(path: "pubspec.yaml").path) {
            f.framework = "Flutter"; f.logo = "flutter"; f.symbol = "bird.fill"
        } else if fm.fileExists(atPath: url.appending(path: "Cargo.toml").path) {
            f.framework = "Rust"; f.logo = "rust"
        } else if fm.fileExists(atPath: url.appending(path: "artisan").path) {
            f.framework = "Laravel"; f.logo = "laravel"
        } else if fm.fileExists(atPath: url.appending(path: "manage.py").path) {
            f.framework = "Django"; f.logo = "django"
        } else if fm.fileExists(atPath: url.appending(path: "go.mod").path) {
            f.framework = "Go"; f.logo = "go"; f.symbol = "chevron.left.forwardslash.chevron.right"
            f.suggested.append(.init(name: "api", command: "go run ."))
        } else if fm.fileExists(atPath: url.appending(path: "Package.swift").path)
                    || fm.fileExists(atPath: url.appending(path: "project.yml").path) {
            f.framework = "Swift"; f.logo = "swift"; f.symbol = "swift"
        } else if fm.fileExists(atPath: url.appending(path: "pyproject.toml").path)
                    || fm.fileExists(atPath: url.appending(path: "requirements.txt").path) {
            f.framework = "Python"; f.logo = "python"; f.symbol = "terminal.fill"
        }
        return f
    }
}

/// Saves workspaces as JSON in Application Support.
enum WorkspaceStore {
    /// Taki's files. Demo mode keeps its own folder, so sample data never touches the real files.
    static var url: URL {
        let dir = Demo.isOn ? FileManager.default.temporaryDirectory.appending(path: "TakiDemo")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Taki")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "workspaces.json")
    }

    static func load() -> [Workspace] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        var list = (try? JSONDecoder().decode([Workspace].self, from: d)) ?? []
        for i in list.indices {   // a hand-edited file must not carry an impossible port
            for j in list[i].services.indices where !(1...65_535).contains(list[i].services[j].port ?? 1) {
                list[i].services[j].port = nil
            }
        }
        return list
    }

    static func save(_ list: [Workspace]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(list) {
            try? d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// A link name safe for `<name>.localhost`: lowercase letters, digits and dashes.
    static func linkName(for name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(s).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "app" : collapsed
    }
}
