import Foundation
import XCTest

@MainActor
final class ReminderEditSessionTests: XCTestCase {
    private func reminder() -> ReminderRecord {
        ReminderRecord(id: "1", listID: "personal", title: "Original", notes: "Keep these notes",
            due: ReminderDue(year: 2026, month: 9, day: 26))
    }

    func testDraftCommitsCurrentValuesAndPreservesUntouchedCalendarComponents() async {
        let original = reminder()
        let session = ReminderEditSession(original)
        session.title = "  Revised  "
        var saved: ReminderRecord?
        let succeeded = await session.commit { saved = $0; return nil }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(saved?.title, "Revised")
        XCTAssertEqual(saved?.notes, original.notes)
        XCTAssertEqual(saved?.due, original.due)
        XCTAssertEqual(session.phase, .saved)
    }

    func testNotesAndDateEditsCommitTogetherAndKeepDateOnlySemantics() async {
        let session = ReminderEditSession(reminder())
        session.notes = "New detail\nSecond line"
        session.dueDate = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        var saved: ReminderRecord?
        let savedSuccessfully = await session.commit { saved = $0; return nil }
        XCTAssertTrue(savedSuccessfully)
        XCTAssertEqual(saved?.notes, "New detail\nSecond line")
        XCTAssertEqual(saved?.due, ReminderDue(year: 2026, month: 10, day: 2))

        let clearing = ReminderEditSession(saved!)
        clearing.notes = ""
        var cleared: ReminderRecord?
        let clearedSuccessfully = await clearing.commit { cleared = $0; return nil }
        XCTAssertTrue(clearedSuccessfully)
        XCTAssertNil(cleared?.notes)
    }

    func testDiscardNeverSavesAndNewSessionStartsFromAuthoritativeRecord() async {
        let original = reminder()
        for _ in 0..<10 {
            let session = ReminderEditSession(original)
            session.title = "Cancelled draft"
            session.discard()
            let succeeded = await session.commit { _ in XCTFail("Discarded draft must not save"); return nil }
            XCTAssertFalse(succeeded)
            XCTAssertEqual(ReminderEditSession(original).title, original.title)
        }
    }

    func testConcurrentCommitTriggersOneMutation() async {
        let session = ReminderEditSession(reminder())
        session.title = "Changed"
        var count = 0
        let first = Task { await session.commit { _ in
            count += 1
            try? await Task.sleep(for: .milliseconds(20))
            return nil
        } }
        await Task.yield()
        let second = await session.commit { _ in count += 1; return nil }
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(second)
        XCTAssertEqual(count, 1)
    }

    func testFailurePreservesDraftAndRetryCanSaveCorrectedValue() async {
        let session = ReminderEditSession(reminder())
        session.title = "First draft"
        let failed = await session.commit { _ in "Offline" }
        XCTAssertFalse(failed)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.title, "First draft")
        session.title = "Corrected draft"
        var savedTitle: String?
        let retried = await session.commit { savedTitle = $0.title; return nil }
        XCTAssertTrue(retried)
        XCTAssertEqual(savedTitle, "Corrected draft")
        XCTAssertNil(session.error)
    }

    func testEmptyTitleCanBeCorrectedWithoutLosingSession() async {
        let session = ReminderEditSession(reminder())
        session.title = "   "
        let invalid = await session.commit { _ in XCTFail("Invalid draft must not save"); return nil }
        XCTAssertFalse(invalid)
        XCTAssertEqual(session.phase, .failed)
        session.title = "Valid"
        let valid = await session.commit { _ in nil }
        XCTAssertTrue(valid)
    }

    func testFailedDraftSurvivesCallerAndRetriesThroughAppState() async {
        let state = AppState(isDemo: true, demoScenario: .mutationFailure)
        await state.refresh()
        let session = ReminderEditSession(state.snapshot.reminders[0])
        session.title = "Recover this draft"
        let first = await state.saveEdit(session, undoManager: nil)
        XCTAssertFalse(first)
        XCTAssertTrue(state.unsavedEdits[session.id] === session)
        let retry = await state.saveEdit(session, undoManager: nil)
        XCTAssertTrue(retry)
        XCTAssertTrue(state.unsavedEdits.isEmpty)
        XCTAssertEqual(state.reminder(for: session.original.id)?.title, "Recover this draft")
    }

    func testRemovedReminderRetainsDraftWithoutRecreatingIt() async {
        let state = AppState(isDemo: true)
        await state.refresh()
        let session = ReminderEditSession(state.snapshot.reminders[0])
        session.title = "Keep this draft"
        state.snapshot.reminders.removeAll { $0.id == session.original.id }
        let saved = await state.saveEdit(session, undoManager: nil)
        XCTAssertFalse(saved)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertTrue(state.unsavedEdits[session.id] === session)
        XCTAssertNil(state.reminder(for: session.original.id))
        state.discardEdit(session)
        XCTAssertTrue(state.unsavedEdits.isEmpty)
    }
}
