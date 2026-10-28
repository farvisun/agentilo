import Foundation

/// Gemini CLI: `<home>/tmp/<project>/chats/session-*.jsonl` (subagents in `chats/<parent>/<id>.jsonl`).
/// Each line is a metadata header, a whole message, or a `$set`/`$patch`/`$rewindTo` update.
/// A message is appended again under the same id when it gains tokens or tool calls, so
/// entries are keyed by message id. Tokens of rewound messages still count: they were spent.
/// Shapes from google-gemini/gemini-cli `packages/core/src/services/chatRecording{Types,Service}.ts`.
public enum GeminiLogParser {
    public static func parse(_ data: Data, into agg: inout FileAggregate) -> Int {
        var seen = Set(agg.entries.lazy.map(\.k).filter { $0 != 0 })
        var seenActivity = Set(agg.activity.lazy.map(\.k).filter { $0 != 0 })
        return LogLines.forEach(in: data, markers: ["\"type\""]) { obj in
            guard let id = J.string(obj["id"]), obj["$patch"] == nil,
                  let date = DateParsing.iso(J.string(obj["timestamp"])) else { return }
            switch J.string(obj["type"]) {
            case "user":
                // Tool results come back as user messages carrying a functionResponse part.
                let parts = (obj["content"] as? [[String: Any]]) ?? []
                guard !parts.contains(where: { $0["functionResponse"] != nil }),
                      seenActivity.insert(FNV.hash("prompt:\(id)")).inserted else { return }
                agg.addActivity(.prompt, id: "prompt:\(id)", at: date)
            case "gemini":
                for call in (obj["toolCalls"] as? [[String: Any]]) ?? [] {
                    guard let cid = J.string(call["id"]), seenActivity.insert(FNV.hash("tool:\(cid)")).inserted else { continue }
                    agg.addActivity(.tool, id: "tool:\(cid)", at: date)
                }
                guard let t = J.dict(obj["tokens"]) else { return }
                let key = FNV.hash("gemini:\(id)")
                guard seen.insert(key).inserted else { return }
                let input = J.double(t["input"]) ?? 0, cached = J.double(t["cached"]) ?? 0
                let output = J.double(t["output"]) ?? 0, thoughts = J.double(t["thoughts"]) ?? 0
                let tool = J.double(t["tool"]) ?? 0
                let total = J.double(t["total"]) ?? (input + output + thoughts + tool)
                let model = J.string(obj["model"]) ?? "gemini"
                // `input` includes `cached`; thinking is billed as output.
                let cost = Pricing.cachedInInputCost(model: model, input: input + tool, cached: cached, output: output + thoughts)
                agg.add(Int(total), weighted: total, cost: cost, model: model, at: date, key: key)
            default:
                break
            }
        }
    }

    public static func parse(_ data: Data) -> FileAggregate {
        var agg = FileAggregate()
        _ = parse(data, into: &agg)
        return agg
    }

    /// The project folder name: `tmp/<project>/chats/...`.
    static func project(for url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.lastIndex(of: "chats"), i > 0 else { return nil }
        return parts[i - 1]
    }
}
