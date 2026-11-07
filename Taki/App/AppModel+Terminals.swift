import Foundation

/// Terminal tabs: opening, naming, closing (asking first when something still runs), switching,
/// and remembering which Claude session each Claude tab holds.
extension AppModel {
    func newTerminal(folder: String, command: String? = nil, title: String? = nil) {
        // The free edition keeps two tabs open at once; the Terminals screen explains why.
        guard terminals.count < Edition.maxTerminals else {
            tabLimitReached = true
            section = .terminals
            return
        }
        tabLimitReached = false
        let tab = TerminalTab(title: title ?? TabKind(command: command).title(for: (folder as NSString).lastPathComponent),
                              folder: folder, command: command)
        if let i = terminals.firstIndex(where: { $0.id == selectedTerminal }) {
            terminals.insert(tab, at: i + 1)                 // next to the current tab, like any tabbed app
        } else {
            terminals.append(tab)
        }
        selectedTerminal = tab.id
        section = .terminals
    }

    /// A new tab of one kind in a folder, named after `name` (the folder's own name by default).
    func newTerminal(_ kind: TabKind, folder: String, name: String? = nil) {
        newTerminal(folder: folder, command: kind.command,
                    title: kind.title(for: name ?? (folder as NSString).lastPathComponent))
    }

    /// The folder the current tab's shell is in, else the default folder.
    var currentTerminalFolder: String {
        selectedTerminal.flatMap { id in
            TerminalRegistry.shared.currentFolder(of: id) ?? terminals.first { $0.id == id }?.folder
        } ?? defaultFolder
    }

    /// A new shell tab in the current tab's folder (Cmd-T).
    func newTerminalTab() { newTerminal(.shell, folder: currentTerminalFolder) }

    /// The same kind of tab in the same folder. A Claude tab starts a new conversation there.
    func duplicateTerminal(_ id: UUID) {
        guard let t = terminals.first(where: { $0.id == id }) else { return }
        guard terminals.count < Edition.maxTerminals else { tabLimitReached = true; return }
        selectedTerminal = id
        newTerminal(t.kind, folder: TerminalRegistry.shared.currentFolder(of: id) ?? t.folder)
    }

    func renameTerminal(_ id: UUID, to name: String) {
        guard let i = terminals.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != displayTitles[id] else { return }     // Return without a change keeps it automatic
        terminals[i].title = clean.isEmpty ? terminals[i].kind.title(for: (terminals[i].folder as NSString).lastPathComponent) : clean
        terminals[i].renamed = !clean.isEmpty
    }

    /// The shell moved to another folder: the tab follows (unless the owner named it).
    func terminalMoved(_ id: UUID, to folder: String) {
        guard let i = terminals.firstIndex(where: { $0.id == id }), terminals[i].folder != folder else { return }
        terminals[i].folder = folder
        if !terminals[i].renamed && terminals[i].kind == .shell {
            terminals[i].title = (folder as NSString).lastPathComponent
        }
    }

    /// Names shown for the tabs; two tabs in folders with the same name become "taki" and "taki 2".
    static func displayTitles(for tabs: [TerminalTab]) -> [UUID: String] {
        var seen: [String: Int] = [:]
        var out: [UUID: String] = [:]
        for t in tabs {
            let n = seen[t.title, default: 0] + 1
            seen[t.title] = n
            out[t.id] = n == 1 ? t.title : "\(t.title) \(n)"
        }
        return out
    }

    func displayTitle(_ t: TerminalTab) -> String { displayTitles[t.id] ?? t.title }

    /// Busy as of the last poll (for the lists). Closing and quitting check again, live.
    func terminalIsBusy(_ id: UUID) -> Bool { busyTabs.contains(id) }

    /// Recomputed every poll: which tabs run something, and the Claude session each Claude tab holds.
    func refreshTerminalFacts() {
        busyTabs = Set(terminals.map(\.id).filter { TerminalRegistry.shared.isBusy($0, parents: parents) })
        var sessions: [UUID: String] = [:]
        for a in agents where a.tool == .claude && AgentScanner.isSessionID(a.id) {
            if let tab = TerminalRegistry.shared.tab(containing: a.pid, parents: parents) { sessions[tab] = a.id }
        }
        for (tab, sid) in sessions {
            if let i = terminals.firstIndex(where: { $0.id == tab }), terminals[i].sessionID != sid { terminals[i].sessionID = sid }
        }
    }

    /// Close, asking first when the tab still runs something (a Claude session, a server, a build).
    func requestClose(_ ids: [UUID]) {
        let parents = ProcessScanner.parentMap()
        let busy = ids.filter { TerminalRegistry.shared.isBusy($0, parents: parents) }
        for id in ids where !busy.contains(id) { closeTerminal(id) }
        if !busy.isEmpty { pendingClose = busy }
    }

    func requestClose(_ id: UUID) { requestClose([id]) }

    func confirmPendingClose() {
        let ids = pendingClose
        pendingClose = []
        for id in ids { closeTerminal(id) }
    }

    func closeOtherTerminals() { requestClose(terminals.map(\.id).filter { $0 != selectedTerminal }) }
    func closeAllTerminals() { requestClose(terminals.map(\.id)) }
    func closeCurrentTerminal() { if let id = selectedTerminal { requestClose(id) } }

    /// Removes the tab and ends its shell. Callers that should ask first go through requestClose.
    func closeTerminal(_ id: UUID) {
        pendingClose.removeAll { $0 == id }                  // a tab that ended by itself leaves the question
        guard let i = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals.remove(at: i)
        tabLimitReached = false                         // there is room again
        TerminalRegistry.shared.remove(id)
        busyTabs.remove(id)
        if selectedTerminal == id {
            selectedTerminal = terminals.indices.contains(i) ? terminals[i].id : terminals.last?.id
        }
    }

    /// Something would be lost on quit: a busy terminal tab or a chat that is working or waiting.
    var quitWarning: String? {
        let parents = ProcessScanner.parentMap()
        let tabs = terminals.filter { TerminalRegistry.shared.isBusy($0.id, parents: parents) }.count
        let chatsBusy = 0
        var parts: [String] = []
        if tabs > 0 { parts.append(Format.plural(tabs, "terminal") + " still running something") }
        if chatsBusy > 0 { parts.append(Format.plural(chatsBusy, "chat") + " still working") }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    /// Cmd-Shift-] / Cmd-Shift-[: the next or previous tab, wrapping around. With no tab selected
    /// yet, ] goes to the first and [ to the last.
    func cycleTerminal(_ step: Int) {
        guard !terminals.isEmpty else { return }
        let i = terminals.firstIndex { $0.id == selectedTerminal } ?? (step > 0 ? -1 : 0)
        selectedTerminal = terminals[(i + step + terminals.count) % terminals.count].id
        section = .terminals
    }

    /// The tab Cmd-1 ... Cmd-9 picks: 1 to 8 by position, 9 always the last (as in Safari and
    /// Terminal). The menu, the shortcut list and the action all use this one mapping.
    func terminalIndex(forShortcut n: Int) -> Int? {
        guard !terminals.isEmpty, (1...9).contains(n) else { return nil }
        let i = n == 9 ? terminals.count - 1 : n - 1
        return terminals.indices.contains(i) ? i : nil
    }

    /// The shortcut number shown next to the tab at `index`, if it has one.
    func shortcut(forTerminalAt index: Int) -> Int? {
        if index < 8 { return index + 1 }
        return index == terminals.count - 1 ? 9 : nil
    }

    func selectTerminal(number n: Int) {
        guard let i = terminalIndex(forShortcut: n) else { return }
        selectedTerminal = terminals[i].id
        section = .terminals
    }

    /// Saves the tabs a second after the last change (a shell changing folders often writes once).
    func scheduleTerminalSave() {
        terminalSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushTerminalSave() }
        terminalSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func flushTerminalSave() {
        terminalSave?.cancel()
        terminalSave = nil
        TerminalStore.save(terminals)
    }
}
