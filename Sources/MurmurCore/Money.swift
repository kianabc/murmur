import Foundation

public enum Money {
    /// Three significant figures — for money actually spent.
    ///
    /// A single cleaned transcript costs a fraction of a cent, so a fixed two
    /// decimals renders real totals as "$0.00" and the tracker looks broken.
    /// Above a dollar it floors at two decimals, because that is what money
    /// looks like.
    public static func format(_ value: Double) -> String {
        guard value > 0 else { return "$0.00" }
        let magnitude = Int(floor(log10(value)))
        let decimals = max(2, 2 - magnitude)
        return String(format: "$%.\(decimals)f", value)
    }

    /// Two decimals — for forward-looking estimates.
    ///
    /// An estimate is a rough guide, and extra digits imply a precision it
    /// doesn't have. "$0.72/mo" is honest; "$0.722/mo" pretends to know.
    public static func estimate(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
