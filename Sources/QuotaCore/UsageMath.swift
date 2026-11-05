import Foundation

public enum UsageMath {
    public static let defaultDailyLimit = 100_000
    public static let defaultSwitchThreshold = 0.75

    /// Free-plan Workers and Pages Functions share one counter that resets at midnight UTC.
    public static func utcDayBounds(containing date: Date, calendar: Calendar? = nil) -> (start: Date, end: Date) {
        let calendar = calendar ?? utcCalendar()
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    public static func ratio(requests: Int, limit: Int) -> Double {
        guard limit > 0 else { return 1 }
        return Double(requests) / Double(limit)
    }

    public static func remaining(requests: Int, limit: Int) -> Int {
        max(0, limit - max(0, requests))
    }

    /// An account is usable when it is enabled, the last fetch succeeded, and usage is under the switch line.
    public static func isUsable(config: AccountConfig, usage: AccountUsage?) -> Bool {
        guard config.enabled, let usage, usage.error == nil else { return false }
        return ratio(requests: usage.requests, limit: config.dailyLimit) < config.switchThreshold
    }

    /// Prefer the usable account with the most headroom. Ties keep the earlier account.
    public static func suggestedAccount(in snapshots: [AccountSnapshot]) -> AccountSnapshot? {
        snapshots
            .filter { isUsable(config: $0.config, usage: $0.usage) }
            .max { lhs, rhs in
                remaining(requests: lhs.usage?.requests ?? 0, limit: lhs.config.dailyLimit)
                    < remaining(requests: rhs.usage?.requests ?? 0, limit: rhs.config.dailyLimit)
            }
    }

    public static func status(accounts: [AccountSnapshot], now: Date) -> QuotaStatus {
        let bounds = utcDayBounds(containing: now)
        return QuotaStatus(
            generatedAt: now,
            resetsAt: bounds.end,
            suggestedAccountID: suggestedAccount(in: accounts)?.config.id,
            accounts: accounts
        )
    }

    /// Menu bar text shows the fullest enabled account. Errors outrank a percentage.
    public static func menuTitle(for snapshots: [AccountSnapshot]) -> String {
        let visible = snapshots.filter(\.config.enabled)
        guard !visible.isEmpty else { return "Quota" }
        if visible.contains(where: { $0.usage?.error != nil }) {
            return "!"
        }
        if visible.contains(where: { $0.usage == nil }) { return "—" }
        let fullest = visible.max { lhs, rhs in
            ratio(requests: lhs.usage?.requests ?? 0, limit: lhs.config.dailyLimit)
                < ratio(requests: rhs.usage?.requests ?? 0, limit: rhs.config.dailyLimit)
        }
        let percent = Int((ratio(
            requests: fullest?.usage?.requests ?? 0,
            limit: fullest?.config.dailyLimit ?? defaultDailyLimit
        ) * 100).rounded())
        return "\(percent)%"
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}
