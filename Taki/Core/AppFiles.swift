import Foundation

/// Where this edition keeps its files: Application Support/Taki for the free edition and
/// Application Support/Taki Pro for Pro, so the two never overwrite each other. Demo mode keeps
/// its own folder, so sample data never touches the real files.
enum AppFiles {
    static var folder: URL {
        let dir = Demo.isOn ? FileManager.default.temporaryDirectory.appending(path: "TakiDemo")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: Edition.name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// True when the app is only the host for unit tests: then it starts nothing, scans nothing,
/// imports nothing and writes none of the user's files.
enum TestHost {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
