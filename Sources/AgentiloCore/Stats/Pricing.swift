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
        /// One-hour cache writes cost 2x input.
        public var cacheWrite1h: Double { input * 2 }
    }

    /// Prefix of the model id -> rate. Longest prefix wins, so "claude-opus-5-5" beats "claude-opus-5".
    /// Source: platform.claude.com/docs/en/about-claude/pricing, 2026-11-04.
    static let table: [(prefix: String, rate: Rate)] = [
        ("claude-fable-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Rate(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Rate(input: 10, output: 50, cacheRead: 1.0)),
        ("claude-mythos-5", Rate(input: 10, output: 50, cacheRead: 1.0)),
        ("claude-opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-sonnet-5-5", Rate(input: 2, output: 10, cacheRead: 0.10)),
        ("claude-sonnet-5", Rate(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", Rate(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-5-5", Rate(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4", Rate(input: 1, output: 5, cacheRead: 0.10)),
        // OpenAI standard tier (Codex), from developers.openai.com/api/docs/pricing, 2026-11-04.
        ("gpt-6.1-sol", Rate(input: 2, output: 10, cacheRead: 0.10)),
        ("gpt-6.1-terra", Rate(input: 1, output: 5, cacheRead: 0.05)),
        ("gpt-6-astra", Rate(input: 10, output: 50, cacheRead: 1.0)),
        ("gpt-6-sol", Rate(input: 2, output: 10, cacheRead: 0.20)),
        ("gpt-6-luna", Rate(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("gpt-5.3-codex", Rate(input: 1.75, output: 14, cacheRead: 0.175)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    public static func rate(for model: String) -> Rate? {
        let m = model.lowercased()
        return table.first { m.hasPrefix($0.prefix) }?.rate
    }

    /// USD for one Claude response, or nil for a model without a known price.
    /// `cacheWrite` is five-minute writes; `fast` is fast mode, twice the price of every token kind.
    public static func cost(
        model: String, input: Double, output: Double, cacheWrite: Double, cacheRead: Double,
        cacheWrite1h: Double = 0, fast: Bool = false
    ) -> Double? {
        guard let r = rate(for: model) else { return nil }
        let base = input * r.input + output * r.output + cacheWrite * r.cacheWrite
            + cacheWrite1h * r.cacheWrite1h + cacheRead * r.cacheRead
        // Haiku 5.5 charges five times as much when a prompt, cache included, passes 100,000 tokens.
        let prompt = input + cacheWrite + cacheWrite1h + cacheRead
        let long = model.lowercased().hasPrefix("claude-haiku-5-5") && prompt > 100_000
        return base * (long ? 5 : 1) * (fast ? 2 : 1) / 1_000_000
    }

    /// For OpenAI and Google, which count cached tokens inside `input` (and reasoning inside `output`).
    public static func cachedInInputCost(model: String, input: Double, cached: Double, output: Double) -> Double? {
        guard let r = rate(for: model) else { return nil }
        return (max(0, input - cached) * r.input + cached * r.cacheRead + output * r.output) / 1_000_000
    }
}
