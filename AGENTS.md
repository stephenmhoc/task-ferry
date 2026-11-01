# Repository guide

- Generate the Xcode project with `xcodegen generate`; edit `project.yml`, not project settings by hand.
- Keep one native app target and avoid runtime dependencies unless a concrete requirement makes one unavoidable.
- The app has two roles: EventKit bridge and remote client. Apple Reminders is always the source of truth.
- Preserve due dates as `ReminderDue` calendar components. Never replace date-only values with absolute `Date` timestamps on the wire.
- Fetch EventKit objects by identifier for each mutation. Do not cache `EKReminder` or `EKCalendar` instances across requests.
- Keep the bridge bound to loopback. Cloudflare Tunnel and Access are separate operational layers.
- Never log or persist credentials outside Keychain.
- Report failures through `Diagnostics`, with a stable area and step. Sentry stays in `CrashReporting.swift` and only gets an error's type and code, never its description or `userInfo`, and never reminder content, hostnames, or URLs. Don't turn on an SDK source that records URLs, screens, or free-form text.
- Every local build is a demo with its own bundle ID, orange icon, and no URL scheme or Services entry, so it can't touch real reminders or the installed app. `TASK_FERRY_DEMO=0` opts out. Only Release-Direct, which `scripts/release.sh` archives, is the real app.
- Run the core tests after substantive model, protocol, or service changes. They are intentionally host-independent because a `MenuBarExtra` app is not a reliable XCTest host.
- Bridges and remote clients update independently. Keep the RPC protocol backward compatible: add optional fields only. When a remote must know that its bridge supports something, bump `RPCRequest.currentProtocolVersion`.
- Keep the launch path lean. Before the first frame, only decide the activation policy and install delegates that must exist at launch. Start syncing in `applicationDidFinishLaunching`, and defer everything else, such as observers, Services, the hotkey, notifications, and Sparkle.
- Work that must outlive a window belongs in the app delegate or `AppState`, never in a view. That includes the Dock badge, stopping `cloudflared` on quit, and sync triggers.
- Never treat an unreadable Keychain item as a missing one. Use `CredentialStore.read(_:)`, which throws for anything but "not found".
- Keep the native window: `NavigationSplitView` for the sidebar and glass buttons in the title bar (`TitlebarButtons`), not hand-animated panes or toolbar items that follow the sidebar's edge.
- `scripts/test-ui.sh` runs the one UI journey on demo data. It's local only, and it stays one journey: prove a UI fix once, then don't keep the check. A window has to be opened by the test, because an app launched that way doesn't open its own.
- Run `scripts/test.sh` before committing. It fetches the pinned connector and regenerates the project.
- Each version's release notes say what changed and, where possible, why.
