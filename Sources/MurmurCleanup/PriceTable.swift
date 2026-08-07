import Foundation
import MurmurCore

/// Keeps model prices current without shipping a new build.
///
/// Providers change pricing on their own schedule, and a compiled-in table goes
/// stale the moment they do. Murmur fetches `prices.json` from its own
/// repository once a day; whatever it finds overlays the built-in defaults.
///
/// This only affects *estimates* — the monthly figure in the picker and any
/// future request. Every logged request stores the price in force at the time,
/// so an update can never rewrite what you've already spent.
public enum PriceTable {
    private static let url = URL(
        string: "https://raw.githubusercontent.com/\(UpdateChecker.repository)/main/prices.json"
    )!
    private static let overridesKey = "com.torimi.murmur.priceOverrides"
    private static let checkedKey = "com.torimi.murmur.priceTableChecked"

    /// `modelID -> (input, output)` in dollars per million tokens.
    public static func overrides() -> [String: (input: Double, output: Double)] {
        guard let raw = UserDefaults.standard.dictionary(forKey: overridesKey) else { return [:] }
        var out: [String: (Double, Double)] = [:]
        for (id, value) in raw {
            guard let pair = value as? [String: Double],
                  let input = pair["input"], let output = pair["output"] else { continue }
            out[id] = (input, output)
        }
        return out
    }

    public static var lastChecked: Date? {
        UserDefaults.standard.object(forKey: checkedKey) as? Date
    }

    static var isDue: Bool {
        guard let last = lastChecked else { return true }
        return Date().timeIntervalSince(last) > 24 * 60 * 60
    }

    /// Fetch and store. Silent on failure — stale prices are a cosmetic problem
    /// and must never interfere with dictation.
    @discardableResult
    public static func refresh(session: URLSession = .shared) async -> Int {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: [String: Double]]
        else { return 0 }

        var accepted: [String: [String: Double]] = [:]
        for (id, prices) in models {
            guard let input = prices["input"], let output = prices["output"] else { continue }
            // Sanity-bound the values. A malformed or hostile file must not be
            // able to claim a model costs $0, which would silently under-report
            // spend, or something absurd that makes the tracker meaningless.
            guard input >= 0, input <= 1_000, output >= 0, output <= 1_000 else { continue }
            // Only models we actually know about.
            guard CleanupModelSpec.find(id) != nil else { continue }
            accepted[id] = ["input": input, "output": output]
        }

        UserDefaults.standard.set(accepted, forKey: overridesKey)
        UserDefaults.standard.set(Date(), forKey: checkedKey)
        Log.echo("prices: refreshed \(accepted.count) model(s)")
        return accepted.count
    }

    public static func refreshIfDue(session: URLSession = .shared) async {
        guard isDue else { return }
        await refresh(session: session)
    }

    /// Forget everything fetched and fall back to the compiled-in table.
    public static func reset() {
        UserDefaults.standard.removeObject(forKey: overridesKey)
        UserDefaults.standard.removeObject(forKey: checkedKey)
    }
}
