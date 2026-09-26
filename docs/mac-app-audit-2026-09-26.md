# Mac app audit and fix plan — September 26, 2026

## Fixes implemented after the audit

The eight findings below have implementation changes in the working tree. The original findings and coverage record are retained as a baseline, not a description of the fixed build.

| Finding | Implementation | Verification |
| --- | --- | --- |
| Inline save/discard and lost drafts | Reference-backed edit sessions; workspace-owned current-session callbacks; single coalesced save; explicit Done/Cancel; failed drafts retained in AppState with Review/Retry/Copy/Discard; untouched due components preserved | Return and Command-Return save; Escape discards; **ten consecutive native save/cancel/reopen cycles passed**; undo/redo passed; simulated failure retained its draft after navigation and Retry saved it; core tests cover coalescing, validation, missing reminders, failure and retry |
| Demo isolation | Demo service survives role reset; isolated preferences; no live Keychain, cache, EventKit/listener, login, notification, shortcut/Services, Cloudflare or Sparkle actions; named fixtures | Dependency spies and remote/bridge/reset tests pass; native remote-to-bridge switch, demo login/notification toggles and disabled Cloudflare setup exercised |
| Quick Entry focus | Use an ordinary panel for in-app invocation; reserve the nonactivating panel for invocation over another app; restore the originating window and dispose of the panel | Reproduced the failure in the nonactivating in-app panel, then verified navigation and Settings shortcuts after submission and cancellation with the corrected panel |
| Editor contrast/compact layout | Neutral editor surface excluded from native blue row selection, with logical selection retained for commands; separate date/time rows; two-row smart-list composer | Light/dark screenshots inspected; 580-point workspace, long title/list name, multiline notes, date+time and scrolling checked; controls remain accessible and readable |
| Filtered selection commands | Intersect selection with visible results; base command enablement on actionable reminders; avoid stealing Search focus | No-results search retained the full query and disabled completion; clearing and navigation worked |
| Empty-list paste/native focus | Keep a stable List beneath its empty-state overlay; restore list focus after editing on the next actor turn | Pasting two lines into a newly created empty list produced two reminders; ordinary composer typing remained functional. Final arrow/Return check was interrupted by the Mac locking |
| Accessibility | Expose color buttons individually with selected values; expose reveal controls; preserve bridge status-row actions | All eleven color buttons appeared in AX; selected Green through AX; bridge-token reveal/hide and connection-code reveal were individually exposed and operated |
| Workflow/presentation details | Select new list and focus composer after sheet dismissal; outlined connection field and adjacent validation/test feedback; role-specific initial window sizes; accurate notification and demo copy | New list opened immediately with composer focused; typed reminder created there; remote settings and bridge/setup inspected in native UI |

Validation: `scripts/test.sh` builds the app, regenerates the Xcode project and passes **86 tests with 0 failures**. UI verification used only `TASK_FERRY_DEMO=1`. No production reminders or credentials were changed. New demo scenarios and appearance/size switches are documented in the README.

Failed drafts survive navigation and window closure while the app runs; they are intentionally not persisted across app termination. The final follow-up moved navigation/window-disappearance saving to the workspace so those paths also read the current session. That last lifecycle adjustment passed build/core tests; its final UI retest was interrupted by macOS locking, and automatic unlock failed.

Remaining release checks below still apply to external services and OS integration: live Cloudflare, notification authorization/delivery, global shortcut from another app, signed distribution/Sparkle, VoiceOver, accessibility appearance settings, and other supported macOS versions were not certified by this demo audit.

## Original audit baseline

The workspace and Settings had a clean native foundation, but inline editing could lose Return saves and retain cancelled drafts. The following sections record the pre-fix evidence and acceptance criteria.

## Test environment and scope

- Reviewed and built commit `195fe8a30677d876cd012689124c1ff0bfd784ad`, including the preceding workspace redesigns and the large Mac integration merge.
- macOS 27.0, build 26A428; local Debug build, version 0.1.15.
- Ran `scripts/test.sh`: **75 tests passed, 0 failures**. The script fetched the pinned connector and regenerated the Xcode project. XcodeGen was missing on this machine and was installed through Homebrew first.
- Used native computer-use actions, accessibility trees, and screenshots to operate the app. Remote and bridge runs both used `TASK_FERRY_DEMO=1`; bridge used `TASK_FERRY_DEMO_ROLE=bridge`.
- Tested the default 920 × 640 point workspace in light appearance. All reminder additions and mutations were in-memory demo data. No production Reminders, credentials, or Cloudflare resources were changed.
- At the initial audit stage, no application source had been changed. The follow-up above records the subsequent implementation. Screenshots were inspected in the audit chat. There is no claim of complete release certification: remaining coverage is listed below.

## Original prioritized work

### 1. P1 — Make inline editing reliably commit and discard

**Confirmed through repeated UI runs, including a clean relaunch.**

Reproduction:

1. Open All Reminders and double-click “Send the quarterly report.”
2. Replace its title with “QA Return persistence.” Inspect the field to confirm the new text is present.
3. Press Return. The editor closes, but the row still says “Send the quarterly report.” Refresh does not recover the change.
4. Reopen the editor. The unsaved draft can still be present.

A related sequence starts with “Call the dentist”: change its title, press Escape, and reopen. The row retains the original title, but the supposedly discarded draft reappears in the editor. Subsequent Return or click-away saving can then be ignored. The failure also occurred with other reminders. In contrast, a first edit committed by selecting another row saved successfully, including a change from date-only to timed, and undo/redo worked.

**Implementation plan:** Investigate the interaction among `onSubmit`, `onDisappear`, `isFinished`, editor identity, and the parent selection/focus handlers. Give each editing session a deliberate lifetime and a single commit/discard path. Initialize drafts from the latest reminder on each new session. Preserve drafts on a failed remote save and provide a retry route; do not mark an unsuccessful save finished. Preserve untouched `ReminderDue` components.

Relevant code: `TaskFerry/Views/ReminderDetailView.swift:91`, `:163`, `:180`; `TaskFerry/Views/RemindersWorkspaceView.swift:405`, `:482`, `:691`, `:752`.

**Acceptance:** title, notes, list, date and time save with Return, Command-Return, click-away, list navigation, and window close. Escape discards them permanently. Ten consecutive edit/save/cancel/reopen cycles behave consistently. Undo/redo restores the complete edited value. A delayed or failed service response does not lose the draft. Cover the edit-session state in core tests and exercise the actual text field with an external demo UI runner.

### 2. P1 — Close the holes in demo isolation before expanding UI automation

**Source-confirmed; the dangerous paths were not executed.** The initial demo service is safe, but the demo flag is not an application-wide boundary:

- `resetMode()` removes the demo service and clears `isStarted`. Choosing the bridge role again reaches the normal service configuration, token generation, and bridge setup paths. `configureService` does not select a demo service in this case.
- The Notifications switch calls the real notification authorization API.
- Open at Login calls the real `SMAppService` registration API.
- Cloudflare setup uses the real OAuth/provisioning flow.

Relevant code: `TaskFerry/AppState.swift:347`, `:389`, `:892`, `:926`, `:938`; `TaskFerry/App/ReminderNotificationScheduler.swift:59`; `TaskFerry/Views/SettingsView.swift:156`; `TaskFerry/Views/CloudflareSetupView.swift`.

**Implementation plan:** Centralize demo dependencies and use an isolated preferences suite. Keep both role choices on the demo service after reset. Stub or explicitly disable notification authorization, login registration, Keychain writes, listener startup, hotkey registration, and Cloudflare operations in demo runs. Add named scenarios for unconfigured, empty, loading, cached/offline, mutation failure, long content, and provisioned-bridge states.

**Acceptance:** every screen and role transition can be exercised with demo mode without real permission prompts, credentials, system registrations, or external resources. Dependency spies prove these calls are absent. This enables the missing integration-state UI coverage below.

### 3. P2 — Restore keyboard routing after floating Quick Entry

**Repeated with computer-use; confirm in a normal foreground session before choosing the fix.** After File → Quick Reminder → Add Reminder, the panel closes and the reminder appears, but Command-2 no longer changes the main workspace. Command-comma and Command-W also stopped acting during the first run. Clicking a composer still allowed text entry and Return submission. Restarting the app restored menu shortcuts; the sequence repeated on a second run.

The automation also encountered menu access timeouts after panel dismissal, so this finding could include a background-activation/tool interaction. It should not be presented as conclusively diagnosed.

**Implementation plan:** Reproduce with the app active, then inspect key/main window restoration and focused scene values. Track the invocation context: a panel opened from Task Ferry should return keyboard control to its originating window; one opened over another app should preserve that app's focus. Check both submission and cancellation, with one and two workspace windows.

Relevant code: `TaskFerry/App/QuickEntryPanelController.swift:29`, `:71`, `:79`; `TaskFerry/TaskFerryApp.swift:89`; `TaskFerry/App/WindowRouter.swift`.

**Acceptance:** navigation, Settings, New Reminder, Close, and Undo work immediately after Quick Entry closes. Global Quick Entry does not unexpectedly bring the workspace forward.

### 4. P2 — Improve the selected inline editor's readability and compact layout

**Visual issue confirmed in light appearance.** The editor uses the list's saturated blue selection background while retaining dark secondary notes, a list-colored completion ring, and red Delete text. The notes, blue/purple ring, and destructive action have weak contrast. The title becomes a stark white strip inside that blue row.

**Implementation plan:** Prefer a neutral editor surface with a subtle selection indicator, or consistently use semantic selected-content colors. Make title, notes, list, date, time, and Delete read as one deliberate editing surface. Adapt the single fixed-size metadata HStack into a wrapping or stacked layout at compact widths. Actual minimum-width clipping was not verified in this run; it is an acceptance test, not a claimed observed defect.

Relevant code: `TaskFerry/Views/ReminderDetailView.swift:50`, `:67`, `:101`; `TaskFerry/Views/RemindersWorkspaceView.swift:482`.

**Acceptance:** legible active/inactive selections in light and dark appearance; no overlapping or inaccessible controls at the 580 × 420 minimum workspace size, with a long list name and both date and time enabled. Test Increased Contrast and Reduce Transparency as well.

### 5. P2 — Make selection-dependent commands reflect visible selection

**Confirmed in the UI and supported by source.** Select a reminder, then search for a term with no matches. The completion toolbar button remains enabled even though there is no visible reminder to act on. Search filters `selectedReminders`, but toolbar/command availability still uses the raw selection set.

**Implementation plan:** Base command availability on actionable visible reminders, and decide explicitly whether filtering clears or preserves hidden selection. Use the same rule in toolbar, Reminder menu, context menu, and keyboard actions.

Relevant code: `TaskFerry/Views/RemindersWorkspaceView.swift:350`, `:570`, `:583`, `:637`.

**Acceptance:** no-results search disables completion, editing, rescheduling, and move commands. Clearing a search restores a coherent selection. Single- and multi-selection follow the same rules.

### 6. P2 — Make paste available in empty workspaces, and verify native list focus

**Source finding plus incomplete UI coverage.** `.pasteDestination` is installed on the populated reminder `List`, but the empty state replaces that List entirely. An empty list therefore has no equivalent workspace paste destination. The attempted multiline-paste test was interrupted by a computer-use clipboard conflict, so the exact user-visible result remains to be confirmed.

**Implementation plan:** Put workspace paste handling on a stable container/focused command path that exists when a list is empty. Preserve ordinary paste into title, notes, search, and composer fields. Verify keyboard focus after selecting a reminder: Return and arrow keys did not act in the initial computer-use checks, while Command-I and double-click did. Investigate this with foreground keyboard testing before attributing it to product code.

Relevant code: `TaskFerry/Views/RemindersWorkspaceView.swift:302`, `:384`, `:405`, `:442`.

**Acceptance:** paste two lines into empty and populated lists, Today, Tomorrow, and All; each produces two reminders in the intended list with the intended due context. Typing and pasting inside an editor never creates extra reminders. Arrow navigation, Shift selection, Command selection, Return, Escape, Delete, copy, and paste work without requiring a mouse recovery step.

### 7. P2 — Verify and repair accessibility exposure of embedded controls

**Accessibility-tree finding, not a completed VoiceOver audit.** The New List/List Info screenshots show eleven color choices, but the computer-use accessibility tree exposes a combined “Color” text entry and no individual color controls. The source already sets color names and selection traits, so inspect the parent accessibility grouping rather than simply adding duplicate labels. The bridge token reveal button was similarly absent from the combined row's tree in this audit.

**Implementation plan:** Preserve accessible child controls in labeled/grouped rows. Check the completion circles, notes, date/time pickers, status messages, and settings toggles with VoiceOver and keyboard navigation. Keep each actionable control independently discoverable.

Relevant code: `TaskFerry/Views/ListEditorSheet.swift:60`; `TaskFerry/Views/SettingsView.swift:372`; `TaskFerry/Views/ReminderDetailView.swift`.

**Acceptance:** each color can be reached, named, selected, and announced without coordinates. Token reveal/hide has an accessible name and action. The selected color and reminder completion state are understandable without color alone.

### 8. P3 — Finish small workflow and presentation details

- **Select a newly created list.** Creating “QA Empty List” succeeded and applied its chosen green color, but the workspace remained on Work. Navigate to the new list and focus its composer after creation.
- **Make connection entry and feedback clearer.** The empty connection-code field has little visual affordance in the grouped row. Validation works, but its neutral message appears below the unrelated cache setting. Put field validation adjacent to the code and distinguish connection-test success from input errors.
- **Tighten setup/bridge presentation.** The shared 920 × 640 window leaves a large empty region under the two onboarding choices and the four bridge status rows. Give these roles a suitable initial size or a bounded content area while preserving user-resized windows.
- **Use conditional notification copy.** “This Mac isn’t signed in to your personal iCloud account” is an assumption, not detected state. Describe what Task Ferry notifications do without asserting the user's account configuration.

## What was exercised

| Surface / change | Result |
| --- | --- |
| Today, Tomorrow, All, Personal, Work | Opened and visually inspected; grouping, counts, overdue labels and date context coherent |
| Long reminder title | Created and verified two-line wrapping at default size |
| Composer / Command-N / Return | Created reminders successfully; list context and no-date behavior checked |
| Inline title and notes display; date/time controls | Inspected; a click-away title + timed-date edit saved; Return/cancel lifecycle fails as described above |
| Completion, edit undo/redo | Command-K completion and Command-Z restoration passed; edit undo and redo restored title/date together |
| Rescheduling and moving | Context-menu Due Today and Move to List succeeded; counts and destination updated |
| Search | Command-F, note-text match, no-results screen, clearing search checked; hidden-selection enablement issue found |
| New List / List Info | Created green list, opened edit sheet, renamed through Return; inspected empty-list state |
| Reminder deletion | Inspected confirmation and verified Cancel preserves data; final permanent-delete button was not exercised |
| Remote General, Connection, Notifications, Advanced | All visually inspected; pane sizes fit; Test Connection and invalid-code validation passed in demo |
| Floating Quick Entry | Opened from File; title, due segment, list picker and Return submission checked; Work selection verified before submission and created in Work |
| Multiple windows | Command-Option-N opened a second workspace with shared data and independent navigation state; close button worked; command focus after Quick Entry needs investigation |
| Sidebar toggle | Hide worked and content expanded |
| Toolbar customization | Opened palette, inserted Refresh, used it, removed it to restore original toolbar |
| Bridge dashboard / General / Bridge / Advanced | Visually inspected in bridge demo |
| Cloudflare setup introduction | Opened and cancelled; did not start live OAuth/provisioning |
| Change Role / onboarding | Inspected confirmation, reset bridge demo to role picker, inspected both choices; did not select a live service path after reset |
| Core model/protocol/services | 75 host-independent tests passed |

## Remaining release checks

These are gaps, not passes. They are part of the implementation/verification plan.

1. **Visual matrix:** minimum and intermediate window sizes, maximized/fullscreen, dark appearance, Increased Contrast, Reduce Transparency, Reduce Motion, very long list names, many reminders, multiline notes, and scrolling while editing. Native edge-drag resize attempts did not change window size through this tool. A per-process dark appearance launch argument did not change the rendered appearance; system appearance was left unchanged.
2. **Native input:** real foreground arrows/Return/Delete, Command-click and Shift-click selection, drag single/multiple reminders to list/Today/Tomorrow, text drops, populated and empty paste, and focus after panel dismissal. Drag attempts did not produce a move through this computer-use session; context-menu moving did. Clipboard automation reported a conflict, so clipboard behavior is unverified.
3. **Menu bar/Dock/lifecycle:** menu-bar Quick Entry, bridge status menu, Dock badge updates and Dock actions, reopen from Dock after all windows close, background bridge, quit cleanup, global shortcut from another app, and login registration. The floating panel was tested; this does not establish menu-bar popover behavior. Dock access timed out through the tool.
4. **External entry points:** Services from another app, taskferry URLs with title/list/due/notes, malformed links, Spotlight, Shortcuts and Siri. Core URL tests passing does not prove these OS routes work.
5. **Sync/error scenarios:** first launch before connection, cached/offline startup, stale-cache labeling, reconnect, failed edit/create/complete, concurrent updates in two windows, network loss, wake, day rollover, bridge-version mismatch, token errors, and retry deduplication against a running bridge.
6. **Notifications:** opt-in, denied authorization, timed/date-only alerts, Complete/Snooze/Tomorrow actions, rescheduling and cancellation. Exercise permission-changing flows only in a suitable isolated test environment after demo boundaries are fixed.
7. **Cloudflare:** domain picker, no-domain state, provisioning success/failure/rollback, removal, connector readiness, and quit cleanup with a real disposable setup.
8. **Distribution/compatibility:** Release-Direct Sparkle Settings/menu/update flow, signed/notarized installation, cold/warm launch timing and Dock bounces, clean install and upgrade from the preceding release, and supported macOS versions beginning at 14. Debug/demo startup cannot validate the real cached launch path or “one bounce” claim.

## Original suggested implementation order

1. Fix inline edit-session behavior and add regression coverage.
2. Isolate all demo dependencies and add deterministic failure/empty/loading fixtures.
3. Reproduce and fix panel/keyboard focus; complete selection, paste and drag coverage.
4. Polish editor contrast/layout and accessibility, then apply the small workflow improvements.
5. Run the expanded UI matrix and live integration checks; run `scripts/test.sh` before each commit as required by the repository guide.

Keep these fixes local to UI/session behavior where possible. Preserve EventKit as the authority, identifier-based mutations, calendar-component due dates, loopback-only bridge binding, Keychain credential handling, lean launch behavior, and backward-compatible RPC fields.
