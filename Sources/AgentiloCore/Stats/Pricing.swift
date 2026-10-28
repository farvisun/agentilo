import Foundation

/// Anthropic and OpenAI API list prices, for a "what would this cost on the API" estimate.
/// Plans are not billed per token; this only puts usage in familiar units.
public enum Pricing {
    /// USD per million tokens.
    public struct Rate: Equatable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        /// Five-minute cache writes cost 1.25x input.
        public var cacheWrite: Double { input * 1.25 }
    }

    /// Prefix of the model id -> rate. Longest prefix wins, so "claude-opus-5-5" beats "claude-opus-5".
    /// Source: Claude API pricing, cached 2026-10-06.
    static let table: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Rate(input: 10, output: 50, cacheRead: 1.0)),
        ("claude-opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-sonnet-5-5", Rate(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", Rate(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", Rate(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-5-5", Rate(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4", Rate(input: 1, output: 5, cacheRead: 0.10)),
        // OpenAI standard tier (Codex), from developers.openai.com/api/docs/pricing, 2026-10-28.
        ("gpt-6.1-sol", Rate(input: 2, output: 10, cacheRead: 0.10)),
        ("gpt-6-astra", Rate(input: 10, output: 50, cacheRead: 1.0)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    public static func rate(for model: String) -> Rate? {
        let m = model.lowercased()
        return table.first { m.hasPrefix($0.prefix) }?.rate
    }

    /// USD for one response, or nil for a model without a known price.
    public static func cost(model: String, input: Double, output: Double, cacheWrite: Double, cacheRead: Double) -> Double? {
        guard let r = rate(for: model) else { return nil }
        return (input * r.input + output * r.output + cacheWrite * r.cacheWrite + cacheRead * r.cacheRead) / 1_000_000
    }

    /// For OpenAI and Google, which count cached tokens inside `input` (and reasoning inside `output`).
    public static func cachedInInputCost(model: String, input: Double, cached: Double, output: Double) -> Double? {
        guard let r = rate(for: model) else { return nil }
        return (max(0, input - cached) * r.input + cached * r.cacheRead + output * r.output) / 1_000_000
    }
}
