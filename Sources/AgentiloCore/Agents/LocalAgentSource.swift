import Darwin
import Foundation

/// One agent found without herdr or hooks: a running Claude Code, Codex or Gemini CLI process
/// and the transcript it writes.
public struct LocalAgent: Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        case working
        /// The last turn ended; the agent waits for the next prompt.
        case finished
    }

    public var agent: String
    public var pid: Int32
    public var sessionID: String
    public var cwd: String?
    public var activity: Activity
    /// The app the agent runs in (`__CFBundleIdentifier` of its environment).
    public var terminalBundleID: String?
    /// Set when the process runs inside a herdr pane; herdr reports those itself.
    public var herdrPane: String?
    public var transcriptPath: String

    public init(
        agent: String, pid: Int32, sessionID: String, cwd: String? = nil, activity: Activity,
        terminalBundleID: String? = nil, herdrPane: String? = nil, transcriptPath: String = ""
    ) {
        self.agent = agent
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.activity = activity
        self.terminalBundleID = terminalBundleID
        self.herdrPane = herdrPane
        self.transcriptPath = transcriptPath
    }
}

/// A running agent CLI process.
public struct AgentProcess: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var provider: Provider
    public var started: Date
    public var cwd: String?
    public var environment: [String: String]

    /// The agent home the process uses: its override variable, else the default.
    public var home: URL {
        let key: String = switch provider {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        default: "GEMINI_CLI_HOME"
        }
        if let v = environment[key], !v.isEmpty {
            // Gemini's variable names the folder that holds `.gemini`.
            return provider == .gemini ? URL(fileURLWithPath: Paths.expand(v)).appendingPathComponent(".gemini")
                : URL(fileURLWithPath: Paths.expand(v))
        }
        let name = provider == .claude ? ".claude" : provider == .codex ? ".codex" : ".gemini"
        return URL(fileURLWithPath: Paths.home).appendingPathComponent(name)
    }

    /// The app the process was started from; every macOS app passes this to its children.
    public var terminalBundleID: String? {
        if let id = environment["__CFBundleIdentifier"], !id.isEmpty { return id }
        return switch environment["TERM_PROGRAM"] {
        case "ghostty": "com.mitchellh.ghostty"
        case "iTerm.app": "com.googlecode.iterm2"
        case "Apple_Terminal": "com.apple.Terminal"
        case "vscode": "com.microsoft.VSCode"
        default: nil
        }
    }
}

/// Finds agents by their processes and reads what they do from their transcripts, so the notch
/// sees agents in any terminal without herdr and before hooks are installed.
public final class LocalAgentSource: @unchecked Sendable {
    private let lock = NSLock()
    /// Parsed transcript state by path, valid while the file's mtime and size are unchanged.
    private var cache: [String: (stamp: String, activity: LocalAgent.Activity?)] = [:]

    public init() {}

    /// Agents with a transcript, and every agent process alive (with or without one).
    public func scan() -> (agents: [LocalAgent], livePIDs: Set<Int32>) {
        let procs = ProcessScanner.agents()
        var claimed = Set<String>()
        var out: [LocalAgent] = []
        // Newest first: it takes the transcript created after it started, leaving older ones
        // to the agents started before it in the same folder.
        for p in procs.sorted(by: { $0.started > $1.started }) {
            guard let file = TranscriptLocator.transcript(for: p, excluding: claimed) else { continue }
            claimed.insert(file.path)
            guard let activity = activity(of: file, provider: p.provider) else { continue }
            out.append(LocalAgent(
                agent: p.provider.rawValue, pid: p.pid,
                sessionID: TranscriptLocator.sessionID(of: file, provider: p.provider),
                cwd: p.cwd, activity: activity, terminalBundleID: p.terminalBundleID,
                herdrPane: p.environment["HERDR_PANE_ID"].flatMap { $0.isEmpty ? nil : $0 },
                transcriptPath: file.path
            ))
        }
        lock.withLock { cache = cache.filter { claimed.contains($0.key) } }
        return (out, Set(procs.map(\.pid)))
    }

    private func activity(of file: URL, provider: Provider) -> LocalAgent.Activity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        // Gemini writes no turn markers: recent writes mean it is working.
        if provider == .gemini { return Date().timeIntervalSince(mtime) < 15 ? .working : .finished }
        let stamp = "\(mtime.timeIntervalSince1970)|\((attrs[.size] as? NSNumber)?.intValue ?? 0)"
        if let hit = lock.withLock({ cache[file.path] }), hit.stamp == stamp { return hit.activity }
        let text = TranscriptTail.tail(of: file, bytes: 64 * 1024).map(\.0) ?? ""
        let a = provider == .codex ? TranscriptActivity.codex(text) : TranscriptActivity.claude(text)
        lock.withLock { cache[file.path] = (stamp, a) }
        return a
    }
}

// MARK: Transcript state

/// Whether a turn is running, from the end of a transcript.
public enum TranscriptActivity {
    /// Claude Code: the last conversation entry decides. A reply that ends the turn
    /// (`stop_reason: end_turn`, or the `turn_duration` note after it) means finished;
    /// a prompt, a tool call or a tool result means working.
    public static func claude(_ text: String) -> LocalAgent.Activity? {
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"type\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "system":
                if obj["subtype"] as? String == "turn_duration" { return .finished }
            case "assistant":
                let message = obj["message"] as? [String: Any]
                switch message?["stop_reason"] as? String {
                case "end_turn", "stop_sequence", "max_tokens", "refusal": return .finished
                default: return .working
                }
            case "user":
                if obj["isMeta"] as? Bool == true { continue }
                // Esc writes this as a user message; the turn is over.
                if line.contains("[Request interrupted by user") { return .finished }
                return .working
            default:
                continue
            }
        }
        return nil
    }

    /// Codex: `task_started` opens a turn, `task_complete` (or an abort) closes it.
    public static func codex(_ text: String) -> LocalAgent.Activity? {
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"event_msg\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let p = obj["payload"] as? [String: Any] else { continue }
            switch p["type"] as? String {
            case "task_started", "user_message": return .working
            case "task_complete", "turn_aborted": return .finished
            default: continue
            }
        }
        return nil
    }
}

// MARK: Finding the transcript

enum TranscriptLocator {
    /// A transcript written to since the process started; started is rounded down a little
    /// because the agent may open a resumed file before it is fully up.
    static func transcript(for p: AgentProcess, excluding: Set<String>, fileManager fm: FileManager = .default) -> URL? {
        let since = p.started.addingTimeInterval(-2)
        let candidates: [URL]
        switch p.provider {
        case .claude:
            guard let cwd = p.cwd else { return nil }
            let dir = p.home.appendingPathComponent("projects").appendingPathComponent(claudeProjectDir(cwd))
            candidates = files(in: dir, suffix: ".jsonl", fm: fm)
        case .codex:
            let cal = Calendar.current
            candidates = (0..<2).flatMap { back -> [URL] in
                guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { return [] }
                let c = cal.dateComponents([.year, .month, .day], from: day)
                let dir = p.home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
                return files(in: dir, suffix: ".jsonl", fm: fm)
            }
        case .gemini:
            let tmp = p.home.appendingPathComponent("tmp")
            candidates = ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [])
                .flatMap { files(in: $0.appendingPathComponent("chats"), suffix: ".jsonl", fm: fm) }
        default:
            return nil
        }
        let recent = candidates
            .filter { !excluding.contains($0.path) }
            .compactMap { url -> (url: URL, modified: Date, created: Date)? in
                guard let a = try? fm.attributesOfItem(atPath: url.path),
                      let m = a[.modificationDate] as? Date, m >= since else { return nil }
                return (url, m, (a[.creationDate] as? Date) ?? m)
            }
            // Codex keeps every folder's rollouts together; read the folder only of recent ones.
            .filter { p.provider != .codex || p.cwd == nil || codexCwd(of: $0.url) == p.cwd }
        // A session begun in this process beats one it resumed, which may belong to another.
        let own = recent.filter { $0.created >= since }
        return (own.isEmpty ? recent : own).max { $0.modified < $1.modified }?.url
    }

    /// Claude Code keeps a folder per working directory, every non-alphanumeric character a dash.
    static func claudeProjectDir(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func sessionID(of file: URL, provider: Provider) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        switch provider {
        case .codex:
            // rollout-2026-11-11T13-18-13-<uuid>: the uuid is the last five dash groups.
            let parts = stem.split(separator: "-")
            return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : stem
        default:
            return stem
        }
    }

    /// The working directory in a Codex rollout's first line (`session_meta`).
    static func codexCwd(of file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64 * 1024) else { return nil }
        let first = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first ?? data[...]
        guard let obj = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else {
            // A very long first line (instructions) is cut; read the field by hand.
            let text = String(decoding: data, as: UTF8.self)
            guard let r = text.range(of: #""cwd":""#) else { return nil }
            let rest = text[r.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        return payload["cwd"] as? String
    }

    private static func files(in dir: URL, suffix: String, fm: FileManager) -> [URL] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(suffix) }
            .map { dir.appendingPathComponent($0) }
    }
}

// MARK: Processes

public enum ProcessScanner {
    /// Agent CLI processes of the current user.
    public static func agents() -> [AgentProcess] {
        let procs = listProcesses()
        var found: [AgentProcess] = []
        for kp in procs {
            let pid = kp.kp_proc.p_pid
            let comm = commName(kp)
            guard couldBeAgent(comm), let (argv, env) = procArgs(pid: pid),
                  let provider = provider(argv: argv, comm: comm) else { continue }
            let tv = kp.kp_proc.p_un.__p_starttime
            found.append(AgentProcess(
                pid: pid, ppid: kp.kp_eproc.e_ppid, provider: provider,
                started: Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000),
                cwd: cwd(pid: pid), environment: env
            ))
        }
        // A wrapper (npm's node launcher) and the agent it starts are one agent: keep the child.
        let parents = Set(found.map { "\($0.ppid)|\($0.provider.rawValue)" })
        return found.filter { !parents.contains("\($0.pid)|\($0.provider.rawValue)") }
    }

    static func couldBeAgent(_ comm: String) -> Bool {
        ["claude", "codex", "gemini", "node", "bun"].contains(comm)
            // Claude Code's native build runs as `versions/2.1.47`.
            || comm.allSatisfy { $0.isNumber || $0 == "." } && comm.contains(".")
    }

    /// Which agent a command line is; nil for anything else (MCP servers, our own hook bridge).
    public static func provider(argv: [String], comm: String) -> Provider? {
        guard let exe = argv.first else { return nil }
        let name = (exe as NSString).lastPathComponent
        if name == "claude" || exe.contains("/claude/versions/") { return .claude }
        if name == "codex" { return .codex }
        if name == "gemini" { return .gemini }
        if name == "node" || name == "bun", argv.count > 1 {
            let script = argv[1]
            if script.contains("@anthropic-ai/claude-code/") || (script as NSString).lastPathComponent == "claude" { return .claude }
            if script.contains("@google/gemini-cli") || (script as NSString).lastPathComponent == "gemini" { return .gemini }
            if script.contains("@openai/codex") || (script as NSString).lastPathComponent == "codex" { return .codex }
        }
        if comm == "claude" { return .claude }
        return nil
    }

    private static func commName(_ kp: kinfo_proc) -> String {
        var comm = kp.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func listProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for processes started between the two calls.
        size += 32 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func procArgs(pid: Int32) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Data(buf.prefix(size)))
    }

    /// `KERN_PROCARGS2` layout: argc (int32), the executable path, NUL padding, then argc
    /// arguments and the environment, each NUL-terminated.
    public static func parseProcArgs(_ data: Data) -> (argv: [String], env: [String: String])? {
        guard data.count > 4 else { return nil }
        let argc = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        let bytes = [UInt8](data.dropFirst(4))
        var i = 0
        // Skip the executable path and its padding.
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        while i < bytes.count, bytes[i] == 0 { i += 1 }
        func next() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
        guard argc >= 0 else { return nil }
        var argv: [String] = []
        for _ in 0..<argc {
            guard let a = next() else { return nil }
            argv.append(a)
        }
        var env: [String: String] = [:]
        // The environment ends at an empty string; what follows is padding.
        while let kv = next(), !kv.isEmpty {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        return (argv, env)
    }

    private static func cwd(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        var path = info.pvi_cdir.vip_path
        let s = withUnsafeBytes(of: &path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return s.isEmpty ? nil : s
    }
}
