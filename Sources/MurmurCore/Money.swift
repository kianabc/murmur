import Foundation

public extension Notification.Name {
    /// Posted after a usage row is written, so open windows can refresh.
    static let murmurUsageRecorded = Notification.Name("com.torimi.murmur.usageRecorded")
}

public enum Money {
    /// Three decimal places. Always exactly three.
    ///
    /// Two decimals shows "$0.00" for every real total, since a cleaned
    /// transcript costs well under a cent. More than three is unreadable.
    public static func format(_ value: Double) -> String {
        String(format: "$%.3f", value)
    }

    /// Two decimals — for forward-looking estimates, where extra digits imply a
    /// precision the guess does not have.
    public static func estimate(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
