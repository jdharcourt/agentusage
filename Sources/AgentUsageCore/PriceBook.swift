import Foundation

public struct PriceBook: Decodable, Sendable {
    public struct Rate: Decodable, Sendable {
        public let input: Double
        public let cached: Double
        public let cacheWrite: Double
        public let output: Double
    }

    public let updated: String
    public let source: String
    public let models: [String: Rate]

    public static func bundled() throws -> Self {
        let bundle = Bundle.main.url(forResource: "AgentUsage_AgentUsageCore", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = bundle.url(forResource: "prices", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func cost(for tokens: Tokens, model: String) -> Double? {
        guard let rate = models[model] ?? models.first(where: {
            model.hasPrefix($0.key + "-") && model.dropFirst($0.key.count + 1).first?.isNumber == true
        })?.value else { return nil }
        return (Double(tokens.input - tokens.cached - tokens.cacheWrite) * rate.input
                + Double(tokens.cached) * rate.cached
                + Double(tokens.cacheWrite) * rate.cacheWrite
                + Double(tokens.output) * rate.output) / 1_000_000
    }
}
