import AppKit
import Darwin

/// Brings the terminal tab that runs a process to the front (Terminal and iTerm), by its tty.
enum HostFocus {
    static func tty(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, UInt32(truncatingIfNeeded: info.e_tdev) != UInt32.max,   // no controlling terminal
              let name = devname(dev_t(truncatingIfNeeded: info.e_tdev), mode_t(S_IFCHR)) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// True when the agent's own tab was found and brought forward.
    @discardableResult
    static func focus(pid: Int32, hostApp: String?) -> Bool {
        guard let host = hostApp else { return false }
        // The tty goes into an AppleScript string, so only plain /dev/ttysNNN names are used.
        guard let tty = tty(of: pid), tty.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") }) else {
            return activate(host)                    // no controlling terminal: bring its app forward at least
        }
        let script: String
        switch host {
        case "Terminal":
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return true
                  end if
                end repeat
              end repeat
            end tell
            return false
            """
        case "iTerm", "iTerm2":
            script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      activate
                      return true
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return false
            """
        default:
            return activate(host)
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error == nil && result?.booleanValue == true { return true }
        // Not allowed to script it, or the tab is gone: bring the app forward at least.
        return activate(host)
    }

    private static func activate(_ host: String) -> Bool {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == host }?.activate() ?? false
    }
}
