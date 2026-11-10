import Foundation
import XCTest

@MainActor
final class DueControlTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// Tuesday, November 10, 2026, at noon.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))! }

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    func testDayLabelsReadLikeReminders() {
        XCTAssertEqual(DueDayText.label(for: day(0), now: now, calendar: calendar), "Today")
        XCTAssertEqual(DueDayText.label(for: day(1), now: now, calendar: calendar), "Tomorrow")
        XCTAssertEqual(DueDayText.label(for: day(-1), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(DueDayText.label(for: day(3), now: now, calendar: calendar), "Friday")
        XCTAssertEqual(DueDayText.label(for: day(6), now: now, calendar: calendar), "Monday")
        XCTAssertEqual(DueDayText.label(for: day(8), now: now, calendar: calendar), "Nov 18")
        XCTAssertEqual(DueDayText.label(for: day(60), now: now, calendar: calendar), "Jan 9, 2027")
    }

    func testQuickChoicesAreTheNextSaturdayAndMonday() {
        let weekend = DueDayText.nextWeekend(after: now, calendar: calendar)
        let week = DueDayText.nextWeek(after: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month, .day, .weekday], from: weekend), DateComponents(month: 11, day: 14, weekday: 7))
        XCTAssertEqual(calendar.dateComponents([.month, .day, .weekday], from: week), DateComponents(month: 11, day: 16, weekday: 2))
    }

    func testPickingTheSameDayKeepsTheOriginalComponents() {
        // A timed reminder from another time zone, opened and put back on the same day.
        let due = ReminderDue(year: 2026, month: 11, day: 12, hour: 8, minute: 30, timeZoneIdentifier: "Europe/London")
        let session = ReminderEditSession(record(due: due))
        session.setDueDay(session.dueDate)
        XCTAssertEqual(session.updated.due, due)
    }

    func testRemovingATimeGoesBackToTheSameDateOnlyComponents() {
        let due = ReminderDue(year: 2026, month: 11, day: 12)
        let session = ReminderEditSession(record(due: due))
        session.setDueTime(hour: 17, minute: 0)
        XCTAssertEqual(session.updated.due?.hasTime, true)
        session.removeDueTime()
        XCTAssertEqual(session.updated.due, due)
    }

    func testADateOnItsOwnStaysDateOnly() {
        let session = ReminderEditSession(record(due: nil))
        session.setDueDay(day(2))
        XCTAssertEqual(session.updated.due?.hasTime, false)
        XCTAssertNil(session.updated.due?.timeZoneIdentifier)
    }

    func testARowWithOnlyNotesOrADateIsNotBlank() {
        let blank = ReminderEditSession(newIn: "work", due: nil)
        XCTAssertTrue(blank.isBlank)
        let notes = ReminderEditSession(newIn: "work", due: nil)
        notes.notes = "Bring the receipts"
        XCTAssertFalse(notes.isBlank)
        XCTAssertTrue(notes.markIncomplete())
        XCTAssertEqual(notes.error, "A reminder needs a title and a list.")
        let dated = ReminderEditSession(newIn: "work", due: nil)
        dated.setDueDay(day(1))
        XCTAssertFalse(dated.isBlank)
    }

    func testASaveKeepsChangesMadeElsewhereToFieldsItDidNotTouch() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let before = try XCTUnwrap(state.snapshot.reminders.first)
        let session = ReminderEditSession(before, connectionRevision: state.connectionRevision)
        // Another Mac changes the notes while this one has the reminder open.
        _ = await state.updateReminder(before, title: before.title, listID: before.listID, due: before.due,
                                       notes: "Changed elsewhere")
        session.title = "Renamed here"
        let saved = await state.saveEdit(session, undoManager: nil)
        XCTAssertTrue(saved)
        let after = try XCTUnwrap(state.reminder(for: before.id))
        XCTAssertEqual(after.title, "Renamed here")
        XCTAssertEqual(after.notes, "Changed elsewhere")
    }

    private func record(due: ReminderDue?) -> ReminderRecord {
        ReminderRecord(id: "1", listID: "work", title: "Call", notes: nil, due: due)
    }
}
