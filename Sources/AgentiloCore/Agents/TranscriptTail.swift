import Foundation

/// The agent's last reply, read from the end of its transcript when the hook did not carry it
/// (older Claude Code, Codex, or a turn that only herdr saw finish).
public enum TranscriptTail {
    /// Only the end of the file is read; a reply is never this far from it.
    static let tailBytes = 256 * 1024

    public static func lastReply(file: URL) -> String? {
        guard let (text, cut) = tail(of: file) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // A tail read usually starts mid-line.
        if cut, !lines.isEmpty { lines.removeFirst() }

        var claudeID: String?
        var claudeParts: [String] = []
        for line in lines.reversed() {
            guard line.contains("\"assistant\"") || line.contains("agent_message") || line.contains("task_complete"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let reply = codexReply(obj) { return reply }
            // Claude streams one content block per line, all sharing the message id.
            if obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any] {
                let id = message["id"] as? String
                if let claudeID, id != claudeID { break }
                let texts = ((message["content"] as? [[String: Any]]) ?? [])
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                if texts.isEmpty && claudeParts.isEmpty { continue }   // tool-use only: keep looking
                claudeID = id
                claudeParts.insert(contentsOf: texts, at: 0)
            }
        }
        let joined = claudeParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func codexReply(_ obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "event_msg", let p = obj["payload"] as? [String: Any] else { return nil }
        switch p["type"] as? String {
        case "task_complete": return (p["last_agent_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        case "agent_message": return (p["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        default: return nil
        }
    }

    private static func tail(of file: URL) -> (String, cut: Bool)? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let cut = size > UInt64(tailBytes)
        try? h.seek(toOffset: cut ? size - UInt64(tailBytes) : 0)
        guard let data = try? h.readToEnd() else { return nil }
        return (String(decoding: data, as: UTF8.self), cut)
    }

    /// Where a session's transcript lives when only its id is known.
    /// Claude: `<home>/projects/<project>/<id>.jsonl`. Codex: `<home>/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`.
    public static func locate(sessionID: String, provider: Provider, homes: [URL], fileManager fm: FileManager = .default) -> URL? {
        for home in homes {
            switch provider {
            case .claude:
                let projects = home.appendingPathComponent("projects")
                for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                    let f = dir.appendingPathComponent("\(sessionID).jsonl")
                    if fm.fileExists(atPath: f.path) { return f }
                }
            case .codex:
                // Recent days only; a running session's file is never older than its start.
                let cal = Calendar.current
                for back in 0..<3 {
                    guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
                    let c = cal.dateComponents([.year, .month, .day], from: day)
                    let dir = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
                    let hit = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).first { $0.hasSuffix("\(sessionID).jsonl") }
                    if let hit { return dir.appendingPathComponent(hit) }
                }
            case .cursor:
                break
            }
        }
        return nil
    }
}

/// A reply cut down for a two-line alert: no Markdown, first sentences only.
public enum ReplyExcerpt {
    public static func make(_ text: String, limit: Int = 600) -> String? {
        var out: [String] = []
        var inFence = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty || line.hasPrefix("|") || line.allSatisfy({ "-=*_".contains($0) }) { continue }
            var l = line
            while let f = l.first, "#>".contains(f) { l.removeFirst() }
            for bullet in ["- ", "* ", "+ "] where l.hasPrefix(bullet) { l.removeFirst(2) }
            out.append(l.trimmingCharacters(in: .whitespaces))
        }
        var s = out.joined(separator: " ")
        // [label](url) → label, then drop emphasis and inline code marks.
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|\*|`)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return s.count > limit ? String(s.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : s
    }
}
