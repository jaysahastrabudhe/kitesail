import Foundation

/// Tiny local log behind the weekly recap: space freed, Memory Guard saves, one score sample per day.
/// Stored in UserDefaults, capped to 60 days, a few KB at most.
enum ActivityLog {
    struct Entry: Codable {
        enum Kind: String, Codable { case freed, guardQuit }
        let date: Date
        let kind: Kind
        let bytes: Int64
    }

    struct Recap: Equatable {
        let freed: Int64
        let guardQuits: Int
        let scoreStart: Int?
        let scoreEnd: Int?
    }

    private static let entriesKey = "activityLog"
    private static let scoresKey = "dailyScores"       // "yyyy-MM-dd" → score
    private static let lastRecapKey = "lastRecapNotification"

    static func record(_ kind: Entry.Kind, bytes: Int64 = 0) {
        var list = entries().filter { $0.date > Date.now.addingTimeInterval(-60 * 86_400) }
        list.append(Entry(date: .now, kind: kind, bytes: bytes))
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: entriesKey)
    }

    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: entriesKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func recordScore(_ score: Int, on date: Date = .now) {
        var scores = UserDefaults.standard.dictionary(forKey: scoresKey) as? [String: Int] ?? [:]
        scores[day(date)] = score
        if scores.count > 60 { scores = Dictionary(uniqueKeysWithValues: scores.sorted { $0.key > $1.key }.prefix(60).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(scores, forKey: scoresKey)
    }

    static func recap(days: Int = 7, now: Date = .now) -> Recap {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = entries().filter { $0.date >= since }
        let scores = (UserDefaults.standard.dictionary(forKey: scoresKey) as? [String: Int] ?? [:])
            .filter { $0.key >= day(since) }.sorted { $0.key < $1.key }
        return summarize(recent, scores: scores.map(\.value))
    }

    /// Pure part of the recap, kept separate so the self-test can check it.
    static func summarize(_ entries: [Entry], scores: [Int]) -> Recap {
        Recap(freed: entries.filter { $0.kind == .freed }.reduce(0) { $0 + $1.bytes },
              guardQuits: entries.filter { $0.kind == .guardQuit }.count,
              scoreStart: scores.first, scoreEnd: scores.last)
    }

    /// True at most once a week; the caller posts the notification.
    static func recapDue(now: Date = .now) -> Bool {
        let last = UserDefaults.standard.object(forKey: lastRecapKey) as? Date
        guard let last else { UserDefaults.standard.set(now, forKey: lastRecapKey); return false }   // start the clock
        guard now.timeIntervalSince(last) >= 7 * 86_400 else { return false }
        UserDefaults.standard.set(now, forKey: lastRecapKey)
        return true
    }

    private static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
