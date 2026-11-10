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

    func testQuittingSavesAnOpenEdit() async {
        let state = AppState(isDemo: true)
        await state.refresh()
        let session = ReminderEditSession(state.snapshot.reminders[0])
        session.title = "Saved on the way out"
        state.unsavedEdits[session.id] = session
        let unsaved = await state.finishEdits()
        XCTAssertTrue(unsaved.isEmpty)
        XCTAssertEqual(state.reminder(for: session.original.id)?.title, "Saved on the way out")
    }

    func testTypingAfterASaveStillSaves() async {
        let state = AppState(isDemo: true)
        await state.refresh()
        let session = ReminderEditSession(state.snapshot.reminders[0])
        session.title = "First"
        state.openEdits[session.id] = session
        _ = await state.finishEdits()
        session.title = "Second"
        XCTAssertEqual(state.editsAtRisk.map(\.id), [session.id])
        let saved = await state.saveEdit(session, undoManager: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(state.reminder(for: session.original.id)?.title, "Second")
    }

    func testFieldsTheFormDoesNotShowDoNotCountAsChanges() async {
        let state = AppState(isDemo: true)
        await state.refresh()
        let reminder = state.snapshot.reminders[0]
        XCTAssertEqual(reminder.hasUnrestorableDetails, false)
        XCTAssertFalse(ReminderEditSession(reminder).hasUnsavedChanges)
    }

    func testQuittingSavesANewReminderStillBeingTyped() async {
        let state = AppState(isDemo: true)
        await state.refresh()
        let session = ReminderEditSession(newIn: "work", due: nil, connectionRevision: state.connectionRevision)
        session.title = "Typed before quitting"
        state.openEdits[session.id] = session
        let unsaved = await state.finishEdits()
        XCTAssertTrue(unsaved.isEmpty)
        XCTAssertTrue(state.snapshot.reminders.contains { $0.title == "Typed before quitting" })
        let again = await state.finishEdits()
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(state.snapshot.reminders.filter { $0.title == "Typed before quitting" }.count, 1)
    }

    func testAFailedNewReminderWaitsForRetry() async {
        let state = AppState(isDemo: true, demoScenario: .mutationFailure)
        await state.refresh()
        let session = ReminderEditSession(newIn: "work", due: nil, connectionRevision: state.connectionRevision)
        session.title = "Try again"
        let first = await state.saveNewReminder(session, undoManager: nil)
        XCTAssertFalse(first.saved)
        XCTAssertEqual(state.unsavedEdits[session.id]?.phase, .failed, "the draft banner offers it")
        let retried = await state.saveEdit(session, undoManager: nil)
        XCTAssertTrue(retried)
        XCTAssertNil(state.unsavedEdits[session.id])
        XCTAssertTrue(state.snapshot.reminders.contains { $0.title == "Try again" })
    }

    func testANewReminderFromAnotherConnectionIsNotSaved() async throws {
        let state = AppState(isDemo: true, snapshotCache: .disabled)
        await state.refresh()
        let session = ReminderEditSession(newIn: "work", due: nil, connectionRevision: state.connectionRevision)
        session.title = "From before"
        try await state.saveRemoteConfiguration(endpoint: "https://other.example.com", clientID: "",
                                                clientSecret: "", bridgeToken: "OTHER")
        await state.refresh()
        let result = await state.saveNewReminder(session, undoManager: nil)
        XCTAssertFalse(result.saved)
        XCTAssertEqual(session.phase, .discarded)
        XCTAssertFalse(state.snapshot.reminders.contains { $0.title == "From before" })
    }

    func testQuittingReportsAnEditThatCouldNotSave() async {
        let state = AppState(isDemo: true, demoScenario: .mutationFailure)
        await state.refresh()
        let session = ReminderEditSession(state.snapshot.reminders[0])
        session.title = "Not saved"
        state.unsavedEdits[session.id] = session
        let unsaved = await state.finishEdits()
        XCTAssertEqual(unsaved.map(\.id), [session.id])
    }

    func testFailedCompletionBringsTheReminderBack() async {
        let state = AppState(isDemo: true, demoScenario: .mutationFailure)
        await state.refresh()
        let reminder = state.snapshot.reminders[0]
        let completed = await state.completeNow([reminder])
        XCTAssertTrue(completed.isEmpty)
        XCTAssertTrue(state.completingIDs.isEmpty)
        XCTAssertTrue(state.allReminders.contains { $0.id == reminder.id })
    }

    func testCompletionLeavesTheListsAtOnce() async {
        let state = AppState(isDemo: true)
        await state.refresh()
        let reminder = state.snapshot.reminders[0]
        let completed = await state.completeNow([reminder])
        XCTAssertEqual(completed, [reminder.id])
        XCTAssertFalse(state.allReminders.contains { $0.id == reminder.id })
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
