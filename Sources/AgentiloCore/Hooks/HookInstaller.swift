import Foundation

/// Adds and removes Agentilo' own entries in an agent's hook config, leaving everything
/// else as it was. Claude Code and Gemini CLI keep hooks in `<home>/settings.json`, Codex in
/// `<home>/hooks.json`; all use `{"hooks": {"<Event>": [{"matcher"?, "hooks": [{"type": "command", "command"}]}]}}`.
/// Gemini names events differently, wants a name per hook and counts timeouts in milliseconds.
public enum HookInstaller {
    /// Trailing shell comment that marks our commands.
    public static let marker = "# agentilo"
    /// Marker used before the app was renamed from Agent Limits; still recognized so a
    /// reinstall replaces those commands instead of adding a second set.
    static let legacyMarker = "# agentlimits"

    static func isOurs(_ command: String) -> Bool {
        command.hasSuffix(marker) || command.hasSuffix(legacyMarker)
    }

    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// Installed, but pointing at another copy of the app or missing events.
        case outdated
        case unsupported(String)
    }

    public static func configURL(for account: Account) -> URL? {
        switch account.provider {
        case .claude: account.homeURL.appendingPathComponent("settings.json")
        case .codex: account.homeURL.appendingPathComponent("hooks.json")
        case .gemini: account.homeURL.appendingPathComponent("settings.json")
        case .cursor: nil
        }
    }

    public static func events(for provider: Provider, approvals: Bool) -> [AgentEventKind] {
        switch provider {
        case .claude:
            [.sessionStart, .prompt, .preTool, .postTool, .notification, .stop, .sessionEnd] + (approvals ? [.permission] : [])
        case .codex:
            [.sessionStart, .prompt, .preTool, .postTool, .stop]
        case .gemini:
            [.sessionStart, .prompt, .preTool, .postTool, .notification, .stop, .sessionEnd]
        case .cursor:
            []
        }
    }

    public static func command(executable: String, provider: Provider, event: AgentEventKind) -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' hook \(provider.rawValue) \(event.rawValue) \(marker)"
    }

    /// How long the agent waits for our hook: seconds, or milliseconds for Gemini.
    /// Approvals wait for the user; the rest return at once.
    public static func timeout(for event: AgentEventKind, approvalTimeout: Int, provider: Provider = .claude) -> Int {
        let seconds = event == .permission ? approvalTimeout + 10 : 5
        return provider == .gemini ? seconds * 1000 : seconds
    }

    // MARK: Status

    public static func status(
        for account: Account, executable: String, approvals: Bool, approvalTimeout: Int = 60,
        fileManager fm: FileManager = .default
    ) -> Status {
        guard let url = configURL(for: account) else { return .unsupported("Cursor has no hooks") }
        let root = (try? read(url)) ?? [:]
        let ours = entries(in: root)
        if ours.isEmpty { return .notInstalled }
        let wanted = events(for: account.provider, approvals: approvals).map {
            "\(command(executable: executable, provider: account.provider, event: $0))|\(timeout(for: $0, approvalTimeout: approvalTimeout, provider: account.provider))"
        }
        let have = ours.map { "\($0.command)|\($0.timeout ?? 0)" }
        return Set(have) == Set(wanted) && have.count == wanted.count ? .installed : .outdated
    }

    /// Our commands currently in the config.
    static func commands(in root: [String: Any]) -> [String] { entries(in: root).map(\.command) }

    static func entries(in root: [String: Any]) -> [(command: String, timeout: Int?)] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { groups -> [(command: String, timeout: Int?)] in
            ((groups as? [[String: Any]]) ?? []).flatMap { group -> [(command: String, timeout: Int?)] in
                ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { h in
                    guard let c = h["command"] as? String, isOurs(c) else { return nil }
                    return (c, h["timeout"] as? Int)
                }
            }
        }
    }

    // MARK: Install / remove

    public static func install(
        for account: Account, executable: String, approvals: Bool, approvalTimeout: Int,
        fileManager fm: FileManager = .default
    ) throws {
        guard let url = configURL(for: account) else { return }
        var root = try read(url)
        root = installed(
            in: removed(from: root), provider: account.provider, executable: executable,
            approvals: approvals, approvalTimeout: approvalTimeout
        )
        try backup(url, fileManager: fm)
        try write(root, to: url)
    }

    public static func uninstall(for account: Account, fileManager fm: FileManager = .default) throws {
        guard let url = configURL(for: account), fm.fileExists(atPath: url.path) else { return }
        let root = try read(url)
        guard !commands(in: root).isEmpty else { return }
        try backup(url, fileManager: fm)
        try write(removed(from: root), to: url)
    }

    static func installed(
        in root: [String: Any], provider: Provider, executable: String, approvals: Bool, approvalTimeout: Int
    ) -> [String: Any] {
        var root = root
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for event in events(for: provider, approvals: approvals) {
            let name = event.hookName(for: provider)
            var groups = (hooks[name] as? [[String: Any]]) ?? []
            var hook: [String: Any] = [
                "type": "command",
                "command": command(executable: executable, provider: provider, event: event),
                "timeout": timeout(for: event, approvalTimeout: approvalTimeout, provider: provider),
            ]
            var group: [String: Any] = [:]
            if provider == .gemini {
                hook["name"] = "agentilo-\(event.rawValue)"
                group["matcher"] = "*"
            }
            group["hooks"] = [hook]
            groups.append(group)
            hooks[name] = groups
        }
        root["hooks"] = hooks
        return root
    }

    /// Drops our commands, then any group or event they leave empty. Other hooks stay untouched.
    static func removed(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let rest = list.filter { !(($0["command"] as? String).map(isOurs) ?? false) }
                if rest.count == list.count { return group }
                if rest.isEmpty { return nil }
                var g = group
                g["hooks"] = rest
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return root
    }

    // MARK: Files

    static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return obj
    }

    static func write(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// Keeps the file as it was before Agentilo first touched it.
    static func backup(_ url: URL, fileManager fm: FileManager) throws {
        let bak = url.appendingPathExtension("agentilo-bak")
        let legacyBak = url.appendingPathExtension("agentlimits-bak")
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: bak.path), !fm.fileExists(atPath: legacyBak.path) else { return }
        try fm.copyItem(at: url, to: bak)
    }

    /// Gemini CLI runs hooks unless `hooksConfig.enabled` is false in `settings.json`.
    public static func geminiHooksEnabled(home: URL) -> Bool {
        let root = (try? read(home.appendingPathComponent("settings.json"))) ?? [:]
        return ((root["hooksConfig"] as? [String: Any])?["enabled"] as? Bool) ?? true
    }

    /// Codex runs hooks only with `hooks = true` under `[features]` in `config.toml`.
    public static func codexHooksEnabled(home: URL) -> Bool {
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return false }
        var inFeatures = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inFeatures = line == "[features]" }
            if inFeatures, line.replacingOccurrences(of: " ", with: "") == "hooks=true" { return true }
        }
        return false
    }
}
