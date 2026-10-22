import AgentLimitsCore
import Foundation

/// `agentlimits hook <agent> <event>`: called by Claude Code and Codex hooks with the hook's
/// JSON on stdin. Forwards it to the running app and always exits 0 quickly, so an agent
/// never slows down or fails because Agent Limits is closed.
enum HookCommand {
    static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 2, let kind = AgentEventKind(rawValue: args[1]) else { return 0 }
        let input = isatty(STDIN_FILENO) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()
        let json = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        let event = AgentEvent.from(
            hookInput: json, agent: args[0], kind: kind, environment: ProcessInfo.processInfo.environment
        )
        _ = await post(event, path: "/v1/events", timeout: 1)
        return 0
    }

    static func post(_ event: AgentEvent, path: String, timeout: TimeInterval) async -> Data? {
        let settings = SettingsStore.load()
        guard settings.apiEnabled, let token = HookToken.load(),
              let url = URL(string: "http://127.0.0.1:\(settings.apiPort)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: HookToken.header)
        req.httpBody = try? APIJSON.encoder.encode(event)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout
        guard let (data, resp) = try? await URLSession(configuration: config).data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
