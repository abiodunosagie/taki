import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let chat: ChatSession
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { MessageRow(message: $0).id($0.id) }
                        if chat.state == .working { TypingRow() }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            ForEach(chat.pending) { PermissionCard(request: $0, chat: chat) }
            composer
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AgentGlyph(tool: .claude, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text([(chat.folder.path as NSString).abbreviatingWithTildeInPath, chat.model, stateText]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(stateColor).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if chat.contextTokens > 0 {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Context \(Int(chat.contextShare * 100))%").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    ThinBar(value: chat.contextShare, color: chat.contextShare > Theme.contextWarn ? Theme.busy : Theme.codexBlue)
                        .frame(width: 90)
                }
            }
            if chat.state == .working || chat.state == .waiting {
                PillButton(title: "Stop") { chat.interrupt() }.help("Interrupt Claude (it keeps the conversation)")
            }
            PillButton(title: "Continue in Claude Code") { model.continueInClaudeCode(chat) }
            .disabled(chat.sessionID == nil).opacity(chat.sessionID == nil ? 0.5 : 1)
            .help("The same conversation in the Claude Code terminal app, in a Taki tab")
            Menu {
                Button("Close chat", role: .destructive) { model.closeChat(chat) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .glassCircle().fixedSize()
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var stateText: String {
        switch chat.state {
        case .starting: "starting"
        case .idle: "ready"
        case .working: "working \(Format.elapsed(since: chat.lastActivity))"
        case .waiting: "waiting for you"
        case let .ended(why): why
        }
    }

    private var stateColor: Color {
        switch chat.state {
        case .working: Theme.busy
        case .waiting: Theme.link
        case .ended: Theme.danger
        default: Theme.secondary
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(chat.messages.isEmpty ? "Message Claude in \(chat.folder.lastPathComponent)" : "Reply to Claude",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...10)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    submit()
                    return .handled
                }
            let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEnded
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(empty ? Theme.tertiary : Theme.claude, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(empty)
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .tileSurface(radius: 16)
        .padding(.leading, 8).padding(.trailing, 16).padding(.bottom, 14).padding(.top, 6)
        .frame(maxWidth: 900)
    }

    private var isEnded: Bool { if case .ended = chat.state { true } else { false } }

    private func submit() {
        guard !isEnded else { return }
        chat.send(draft)
        draft = ""
    }
}

struct MessageRow: View {
    let message: ChatSession.Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.tileRaised, in: .rect(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            Text(markdown(message.text)).textSelection(.enabled).font(.system(size: 14)).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(spacing: 8) {
                Image(systemName: icon(message.text)).foregroundStyle(message.isError ? Theme.danger : .secondary)
                    .frame(width: 16)
                Text(message.text).font(.system(size: 12, weight: .semibold))
                Text(message.detail).font(Theme.mono).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .tileSurface(radius: 9)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    private func icon(_ tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Edit", "Write", "NotebookEdit": "pencil"
        case "Read": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        default: "wrench.and.screwdriver"
        }
    }
}

struct TypingRow: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .onAppear { on = true }
    }
}

/// Claude asked to run a tool that needs approval.
struct PermissionCard: View {
    let request: PermissionRequest
    let chat: ChatSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.busy)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude wants to use \(request.toolName)").font(.system(size: 13, weight: .semibold))
                Text(request.summary).font(Theme.mono).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            Spacer()
            PillButton(title: "Deny") { chat.answer(request, allow: false) }
                .keyboardShortcut(.escape, modifiers: [])
            Button { chat.answer(request, allow: true) } label: {
                Text("Allow").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 8).background(Theme.link, in: .capsule)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Cmd-Return")
        }
        .padding(14)
        .tileSurface(radius: 14)
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, style: .continuous)
                .fill(Theme.busy).frame(width: 3)
        }
        .padding(.horizontal, 22).padding(.bottom, 8)
        .frame(maxWidth: 900)
    }
}
