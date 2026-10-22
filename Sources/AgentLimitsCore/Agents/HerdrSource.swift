import Foundation

/// One agent as herdr sees it (`herdr agent list`).
public struct HerdrAgent: Equatable, Sendable {
    public enum Status: String, Sendable {
        case working
        case blocked
        case idle
        case unknown
    }

    public var agent: String
    public var status: Status
    public var sessionID: String?
    public var cwd: String?
    public var title: String?
    public var focused: Bool
    public var location: HerdrLocation
}

/// Reads agent state from herdr, the terminal workspace manager, through its CLI.
public enum HerdrSource {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(Paths.home)/.local/bin", "\(Paths.home)/.cargo/bin"]

    public static var executable: String? {
        searchPaths.map { "\($0)/herdr" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Agents in the running herdr session; nil when herdr is missing or not running.
    public static func list() -> [HerdrAgent]? {
        guard let exe = executable, let out = run(exe, ["agent", "list"], timeout: 3) else { return nil }
        return parse(out)
    }

    /// Shows the agent's pane in herdr. The terminal app itself is brought forward by the caller.
    @discardableResult
    public static func focus(pane: String) -> Bool {
        guard let exe = executable else { return false }
        return run(exe, ["agent", "focus", pane], timeout: 3) != nil
    }

    public static func parse(_ data: Data) -> [HerdrAgent]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return nil }
        return agents.compactMap { a in
            guard let pane = a["pane_id"] as? String else { return nil }
            let session = a["agent_session"] as? [String: Any]
            let title = (a["terminal_title_stripped"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return HerdrAgent(
                agent: (a["agent"] as? String) ?? "agent",
                status: HerdrAgent.Status(rawValue: (a["agent_status"] as? String) ?? "") ?? .unknown,
                sessionID: session?["value"] as? String,
                cwd: (a["foreground_cwd"] as? String) ?? (a["cwd"] as? String),
                title: title,
                focused: (a["focused"] as? Bool) ?? false,
                location: HerdrLocation(pane: pane, tab: a["tab_id"] as? String, workspace: a["workspace_id"] as? String)
            )
        }
    }

    /// Runs a command and returns stdout when it exits 0 within the timeout.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return p.terminationStatus == 0 ? data : nil
    }
}
