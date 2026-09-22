# Repository guide

- Generate the Xcode project with `xcodegen generate`; edit `project.yml`, not project settings by hand.
- Keep one native app target and avoid runtime dependencies unless a concrete requirement makes one unavoidable.
- The app has two roles: EventKit bridge and remote client. Apple Reminders is always the source of truth.
- Preserve due dates as `ReminderDue` calendar components. Never replace date-only values with absolute `Date` timestamps on the wire.
- Fetch EventKit objects by identifier for each mutation. Do not cache `EKReminder` or `EKCalendar` instances across requests.
- Keep the bridge bound to loopback. Cloudflare Tunnel and Access are separate operational layers.
- Never log or persist credentials outside Keychain.
- Use `TASK_FERRY_DEMO=1` for UI verification so tests cannot mutate real reminders or trigger privacy prompts.
- Run the core tests after substantive model, protocol, or service changes. They are intentionally host-independent because a `MenuBarExtra` app is not a reliable XCTest host.
- Bridges and remote clients update independently. Keep the RPC protocol backward compatible: add optional fields only. When a remote must know that its bridge supports something, bump `RPCRequest.currentProtocolVersion`.
- Keep the launch path lean. Before the first frame, only decide the activation policy and install delegates that must exist at launch. Start syncing in `applicationDidFinishLaunching`, and defer everything else, such as observers, Services, the hotkey, notifications, and Sparkle.
- Work that must outlive a window belongs in the app delegate or `AppState`, never in a view. That includes the Dock badge, stopping `cloudflared` on quit, and sync triggers.
- Never treat an unreadable Keychain item as a missing one. Use `CredentialStore.read(_:)`, which throws for anything but "not found".
- Run `scripts/test.sh` before committing. It fetches the pinned connector and regenerates the project.
