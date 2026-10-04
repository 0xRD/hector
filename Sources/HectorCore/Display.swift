import Foundation

/// Dates and numbers as Hector shows them. The interface is English only, so the words must be
/// English ("2 hours ago", "Oct 4"), while the user's region keeps its conventions (24-hour
/// clock, digit grouping). `Locale.current` alone would mix languages: "il y a 2 heures" in an
/// English sentence.
public enum Display {
    public static let locale: Locale = {
        var components = Locale.Components(languageCode: .english)
        components.languageComponents.region = Locale.current.region
        components.region = Locale.current.region
        components.hourCycle = Locale.current.hourCycle
        return Locale(components: components)
    }()

    /// 113,627 (or 113 627, depending on the region).
    public static func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    /// "14:05" or "2:05 PM"; `seconds` adds them.
    public static func time(_ date: Date, seconds: Bool = false) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: seconds ? .standard : .shortened).locale(locale))
    }

    /// "Oct 4, 2026"
    public static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    /// "Oct 4, 2026 at 14:05"; `seconds` adds them.
    public static func dateTime(_ date: Date, seconds: Bool = false) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: seconds ? .standard : .shortened).locale(locale))
    }

    /// "a", "a and b", "a, b and c". Not `ListFormatter`, which joins in the system language.
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// "2 hours ago", "yesterday"
    public static func relative(_ date: Date) -> String {
        date.formatted(Date.RelativeFormatStyle(presentation: .named).locale(locale))
    }
}
