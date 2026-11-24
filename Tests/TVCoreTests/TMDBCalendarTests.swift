import Foundation
import Testing
@testable import TVCore

@Test func calendarWeekReadsAsCurrentOnlyWhileItCoversToday() throws {
    let json = """
    {"kind":"anime","source":"bangumi","fallback":false,"stale":false,"timeZone":"Asia/Shanghai",
     "days":[{"date":"2026-11-23","weekday":1,"items":[{"title":"A","originalTitle":"A","links":[]}]},
             {"date":"2026-11-29","weekday":7,"items":[]}],
     "attribution":[]}
    """
    let week = try JSONDecoder().decode(TMDBCalendar.Week.self, from: Data(json.utf8))
    func at(_ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
    }
    // The days run Monday 23 to Sunday 29; the 30th already belongs to the next week.
    #expect(week.current(at(23)))
    #expect(week.current(at(29)))
    #expect(!week.current(at(30)))
    #expect(week.today(at(29))?.weekday == 7)
    #expect(week.today(at(30)) == nil)
}
