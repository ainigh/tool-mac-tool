import Foundation

/// The date, time and place, spelled out for the model so it never has to work them out: the
/// weekday and month in words, the part of the day, the time zone and its offset, the week of
/// the year, and where the user is.
public enum NowContext {
    /// "late night", "early morning", "morning", "midday", "afternoon", "evening" or "night".
    public static func partOfDay(hour: Int, minute: Int = 0) -> String {
        switch hour {
        case 0..<5: return "late night"
        case 5..<8: return "early morning"
        case 8..<12: return "morning"
        case 12: return minute < 30 ? "midday" : "afternoon"
        case 13..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }

    /// "UTC+1", "UTC−4", "UTC+5:30", "UTC".
    public static func offset(_ seconds: Int) -> String {
        if seconds == 0 { return "UTC" }
        let sign = seconds < 0 ? "−" : "+"
        let minutes = abs(seconds) / 60
        let h = minutes / 60, m = minutes % 60
        return "UTC\(sign)\(h)" + (m == 0 ? "" : String(format: ":%02d", m))
    }

    /// "New York" from "America/New_York": the city a time zone is named after.
    public static func city(of zone: TimeZone) -> String? {
        let id = zone.identifier
        guard id.contains("/"), let last = id.split(separator: "/").last else { return nil }
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// The paragraph that goes into the system message.
    public static func describe(_ date: Date, zone: TimeZone, location: String = "", clock24: Bool = false) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        cal.locale = Locale(identifier: "en_US_POSIX")
        func format(_ pattern: String, _ d: Date = date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = pattern
            return f.string(from: d)
        }
        let c = cal.dateComponents([.hour, .minute, .weekday, .year, .dayOfYear], from: date)
        let hour = c.hour ?? 0, minute = c.minute ?? 0
        let weekday = format("EEEE")
        let part = partOfDay(hour: hour, minute: minute)
        let day = format("EEEE d MMMM yyyy")
        let time12 = format("h:mm a"), time24 = format("HH:mm")
        let time = clock24 ? "\(time24) (\(time12))" : "\(time12) (\(time24))"
        let weekend = c.weekday == 1 || c.weekday == 7
        let tomorrow = cal.date(byAdding: .day, value: 1, to: date).map { format("EEEE d MMMM", $0) } ?? ""
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = zone
        let week = iso.component(.weekOfYear, from: date)
        let offsetText = offset(zone.secondsFromGMT(for: date))
        let abbreviation = zone.abbreviation(for: date).flatMap { $0.hasPrefix("GMT") ? nil : $0 }
        let zoneText = zone.identifier + " (" + [abbreviation, offsetText].compactMap { $0 }.joined(separator: ", ") + ")"
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let whereText = !place.isEmpty ? "The user is in \(place)."
            : city(of: zone).map { "The user is probably in or near \($0) (going by the time zone)." } ?? ""

        return """
            Current date and time (already worked out; use it as given, there's no need to reason about it): \
            it is \(weekday) \(part), \(day), at \(time), in the \(zoneText) time zone. \
            Today is a \(weekend ? "weekend day" : "weekday"); tomorrow is \(tomorrow). \
            It's week \(week) of the year and day \(c.dayOfYear ?? 0) of \(c.year ?? 0). \(whereText)
            """.trimmingCharacters(in: .whitespaces)
    }
}
