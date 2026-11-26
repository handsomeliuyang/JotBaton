@testable import CoreLocalization
@testable import RemarcFeature
import Testing
import Foundation

@Suite("Compact timestamp formatting")
@MainActor
struct CompactTimestampTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return calendar.date(from: components)!
    }

    private func formattedTime(_ date: Date, use24Hour: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = L10n.locale
        formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    @Test("today, 24-hour mode: time only, no date separator, no meridiem")
    func todayTwentyFourHour() {
        let now = makeDate(year: 2026, month: 5, day: 15, hour: 15, minute: 30)
        let created = makeDate(year: 2026, month: 5, day: 15, hour: 14, minute: 15)
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now, calendar: calendar)
        let symbols = DateFormatter()
        symbols.locale = L10n.locale
        #expect(result == "14:15")
        #expect(!result.contains("-"))
        #expect(!result.contains(symbols.amSymbol) && !result.contains(symbols.pmSymbol))
    }

    @Test("today, 12-hour mode: includes a meridiem")
    func todayTwelveHour() {
        let now = makeDate(year: 2026, month: 5, day: 15, hour: 15, minute: 30)
        let created = makeDate(year: 2026, month: 5, day: 15, hour: 14, minute: 15)
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: false, now: now, calendar: calendar)
        let symbols = DateFormatter()
        symbols.locale = L10n.locale
        #expect(result == formattedTime(created, use24Hour: false))
        #expect(result.contains(":"))
        #expect(result.contains(symbols.amSymbol) || result.contains(symbols.pmSymbol))
    }

    @Test("yesterday, 24-hour mode: localized Yesterday prefix with 24-hour time")
    func yesterdayTwentyFourHour() {
        let now = makeDate(year: 2026, month: 5, day: 15, hour: 15, minute: 30)
        let created = makeDate(year: 2026, month: 5, day: 14, hour: 9, minute: 5)
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now, calendar: calendar)
        #expect(result == L10n.tr("Yesterday \("09:05")"))
    }

    @Test("yesterday, 12-hour mode: localized Yesterday prefix with 12-hour meridiem time")
    func yesterdayTwelveHour() {
        let now = makeDate(year: 2026, month: 5, day: 15, hour: 15, minute: 30)
        let created = makeDate(year: 2026, month: 5, day: 14, hour: 21, minute: 5)
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: false, now: now, calendar: calendar)
        let expectedTime = formattedTime(created, use24Hour: false)
        let symbols = DateFormatter()
        symbols.locale = L10n.locale
        #expect(result == L10n.tr("Yesterday \(expectedTime)"))
        #expect(result.contains(symbols.amSymbol) || result.contains(symbols.pmSymbol))
    }

    @Test("crossing midnight switches immediately to yesterday even within minutes")
    func acrossMidnight() {
        let now = makeDate(year: 2026, month: 5, day: 15, hour: 0, minute: 5)
        let lastNight = makeDate(year: 2026, month: 5, day: 14, hour: 23, minute: 50)
        let justAfterMidnight = makeDate(year: 2026, month: 5, day: 15, hour: 0, minute: 1)

        #expect(lastNight.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now, calendar: calendar)
            == L10n.tr("Yesterday \("23:50")"))
        #expect(justAfterMidnight.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now, calendar: calendar)
            == "00:01")
    }

    @Test("earlier than yesterday uses the supplied exportDateFormat")
    func olderUsesDateFormat() {
        let now = makeDate(year: 2026, month: 5, day: 15, hour: 15, minute: 30)
        let created = makeDate(year: 2026, month: 5, day: 13, hour: 23, minute: 59)
        let iso = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now, calendar: calendar)
        #expect(iso == "2026-05-13")

        let european = created.remarcCompactTimestamp(dateFormat: .european, use24Hour: true, now: now, calendar: calendar)
        #expect(european == "13/05/2026")
        #expect(iso != european)
    }

    @Test("the tier progresses through today, yesterday, and date as `now` advances")
    func dayBoundaryProgression() {
        let created = makeDate(year: 2026, month: 5, day: 14, hour: 23, minute: 50)
        let sameDay = created.remarcCompactTimestamp(
            dateFormat: .iso, use24Hour: true,
            now: makeDate(year: 2026, month: 5, day: 14, hour: 23, minute: 59),
            calendar: calendar
        )
        let nextDay = created.remarcCompactTimestamp(
            dateFormat: .iso, use24Hour: true,
            now: makeDate(year: 2026, month: 5, day: 15, hour: 0, minute: 1),
            calendar: calendar
        )
        let twoDaysLater = created.remarcCompactTimestamp(
            dateFormat: .iso, use24Hour: true,
            now: makeDate(year: 2026, month: 5, day: 16, hour: 0, minute: 1),
            calendar: calendar
        )

        #expect(sameDay == "23:50")
        #expect(nextDay == L10n.tr("Yesterday \("23:50")"))
        #expect(twoDaysLater == "2026-05-14")
    }
}

@Suite("App display name normalization")
struct AppDisplayNameTests {
    @Test("strips trailing .app suffix case-insensitively")
    func stripsAppExtension() {
        #expect(normalizedAppDisplayName("Google Chrome.app") == "Google Chrome")
        #expect(normalizedAppDisplayName("Safari.APP") == "Safari")
        #expect(normalizedAppDisplayName("Visual Studio Code.App") == "Visual Studio Code")
    }

    @Test("preserves names without trailing .app suffix")
    func preservesPlainNames() {
        #expect(normalizedAppDisplayName("Google Chrome") == "Google Chrome")
        #expect(normalizedAppDisplayName("My.app.tool") == "My.app.tool")
        #expect(normalizedAppDisplayName(".app") == ".app")
    }
}
