import Foundation

/// Snooze choices and wake labels, ported from client-runtime's `threadSettled.ts`
/// (`resolveSnoozePresets`, `snoozeWakeLabel`, `resolveCustomSnooze`) and the web sidebar's
/// `snoozeWakeDescription`, so a snooze reads the same on every client.
enum Snooze {
    static let morningHour = 9
    static let eveningHour = 18

    struct Preset: Identifiable, Hashable {
        enum Kind: String, Hashable { case hour, threeHours, evening, tomorrow, nextWeek }

        var kind: Kind
        var date: Date
        /// The menu row's time column: "9:00", or "Mon 9:00" for next week.
        var whenLabel: String
        var id: Kind { kind }

        var title: String {
            switch kind {
            case .hour: String(localized: "In 1 hour")
            case .threeHours: String(localized: "In 3 hours")
            case .evening: String(localized: "This evening")
            case .tomorrow: String(localized: "Tomorrow")
            case .nextWeek: String(localized: "Next week")
            }
        }
    }

    /// "In 1 hour", "In 3 hours", "This evening" (only while 18:00 is more than an hour away),
    /// "Tomorrow" at 9:00 and "Next week" (Monday 9:00, dropped when it is the same instant as
    /// Tomorrow, i.e. on Sundays).
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [Preset] {
        let inAnHour = now.addingTimeInterval(3600)
        let inThreeHours = now.addingTimeInterval(3 * 3600)
        var presets = [
            Preset(kind: .hour, date: inAnHour, whenLabel: timeOfDay(inAnHour, calendar: calendar)),
            Preset(kind: .threeHours, date: inThreeHours, whenLabel: timeOfDay(inThreeHours, calendar: calendar)),
        ]
        let evening = at(hour: eveningHour, on: now, calendar: calendar)
        if evening.timeIntervalSince(now) > 3600 {
            presets.append(Preset(kind: .evening, date: evening, whenLabel: timeOfDay(evening, calendar: calendar)))
        }
        // Calendar-day arithmetic, not +24 h, so DST days land on the right local day.
        let tomorrow = at(hour: morningHour, on: calendar.date(byAdding: .day, value: 1, to: now) ?? now, calendar: calendar)
        presets.append(Preset(kind: .tomorrow, date: tomorrow, whenLabel: timeOfDay(tomorrow, calendar: calendar)))
        let weekday = calendar.component(.weekday, from: now)  // 1 = Sunday … 7 = Saturday
        let daysUntilMonday = (2 - weekday + 7) % 7 == 0 ? 7 : (2 - weekday + 7) % 7
        let nextWeek = at(hour: morningHour, on: calendar.date(byAdding: .day, value: daysUntilMonday, to: now) ?? now, calendar: calendar)
        if nextWeek != tomorrow {
            presets.append(Preset(
                kind: .nextWeek, date: nextWeek,
                whenLabel: "\(weekdayShort(nextWeek, calendar: calendar)) \(timeOfDay(nextWeek, calendar: calendar))"
            ))
        }
        return presets
    }

    /// Compact "wakes in" label for snoozed rows: "45m", "18h", "3d". Minutes round up, so a
    /// snooze never reads "0m" while the thread is still hidden.
    static func wakeLabel(until wake: Date, now: Date = Date()) -> String {
        let remaining = wake.timeIntervalSince(now)
        if remaining <= 0 { return String(localized: "now") }
        if remaining < 3600 { return String(localized: "\(max(1, Int((remaining / 60).rounded(.up))))m") }
        if remaining < 86_400 { return String(localized: "\(Int((remaining / 3600).rounded(.up)))h") }
        return String(localized: "\(Int((remaining / 86_400).rounded(.up)))d")
    }

    /// Wake time for menus: "17:30" today, "tomorrow 9:00", "Mon 9:00" within a week, else "Oct 12, 9:00".
    static func wakeDescription(until wake: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = timeOfDay(wake, calendar: calendar)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: wake)).day ?? 0
        if days <= 0 { return time }
        if days == 1 { return String(localized: "tomorrow \(time)") }
        if days < 7 { return "\(weekdayShort(wake, calendar: calendar)) \(time)" }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        style = style.month(.abbreviated).day()
        return "\(wake.formatted(style)), \(time)"
    }

    enum DurationUnit: String, CaseIterable, Identifiable {
        case minutes, hours, days
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .minutes: 60
            case .hours: 3600
            case .days: 86_400
            }
        }
        var title: String {
            switch self {
            case .minutes: String(localized: "Minutes")
            case .hours: String(localized: "Hours")
            case .days: String(localized: "Days")
            }
        }
    }

    enum CustomInput {
        /// A local calendar day (its date part) and a time of day (its hour and minute).
        case date(day: Date, time: Date)
        /// Elapsed time from now; the amount is typed, so it may be anything.
        case duration(amount: String, unit: DurationUnit)
    }

    /// The custom sheet's wake time, or nil when the input is invalid or not in the future.
    static func resolveCustom(_ input: CustomInput, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let wake: Date
        switch input {
        case let .duration(amount, unit):
            let normalized = amount.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
            wake = now.addingTimeInterval(value * unit.seconds)
        case let .date(day, time):
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            let clock = calendar.dateComponents([.hour, .minute], from: time)
            parts.hour = clock.hour
            parts.minute = clock.minute
            parts.second = 0
            guard let resolved = calendar.date(from: parts) else { return nil }
            // A time skipped by a DST change resolves to another wall-clock time: reject it.
            let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resolved)
            guard check.year == parts.year, check.month == parts.month, check.day == parts.day,
                  check.hour == parts.hour, check.minute == parts.minute else { return nil }
            wake = resolved
        }
        return wake > now ? wake : nil
    }

    private static func at(hour: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    private static func timeOfDay(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                        calendar: calendar, timeZone: calendar.timeZone))
    }

    private static func weekdayShort(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated))
    }
}
