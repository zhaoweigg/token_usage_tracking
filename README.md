# Headroom

A standalone SwiftUI iOS app for tracking personal Claude and ChatGPT/Codex subscription usage across multiple accounts. Sign-in sessions, usage reads, history, and widget snapshots stay on the iPhone. No Mac companion or hosted backend is required.

The app starts empty. Upgrading removes the old seeded demo accounts and sample readings while preserving real manual accounts. There is no restore-demo action or production sample-data factory.

The Apricot design uses warm ivory backgrounds, paper cards, rust accents, and peach usage tracks. Dark mode uses cocoa surfaces and pale apricot accents. Manrope is bundled locally in four weights for both the app and widget, with Dynamic Type support. The font is distributed under the SIL Open Font License in `HeadroomShared/Fonts/Manrope-OFL.txt`.

## Connect an account

1. Tap **Connect account**, select Claude or ChatGPT, and optionally name the account.
2. For Claude, tap **Continue in browser**, sign in and approve profile access, then copy the complete authorization code back into Headroom (including `#state`). This uses the iPhone's browser, allowing Google and passkey sign-in. Claude's consent screen may identify Claude Code: the integration uses its public PKCE client, following Usage4Claude. Only `user:profile` is requested.
3. For ChatGPT, tap **Get sign-in code**, then **Copy code and open browser**. Sign in at `auth.openai.com`, enter that code, approve, and return to Headroom. Approval and Codex usage are checked automatically while this screen is open. Device-code login must be enabled in ChatGPT Settings → Security (or by a workspace admin). If unavailable, choose **Use browser return link instead**, complete browser authorization, then paste the complete `http://localhost:1455/auth/callback?...` address into Headroom. The expected localhost error page does not require a local server.
4. Confirm the displayed identity and tap **Connect account**. Repeat for another account.

Claude's browser authorization uses PKCE and a state check, followed by native requests to `/api/oauth/profile` and `/api/oauth/usage`. ChatGPT uses Codex device authorization, with an optional PKCE/state-checked browser return-link flow, then reads `/backend-api/wham/usage` directly with the authorized account ID. Both providers save access and refresh credentials separately per account in the iPhone Keychain, with refresh-token rotation and removal on account deletion. No local callback server or Mac is needed. Browser-return attempts expire after ten minutes; device-code attempts expire after fifteen. Device polling runs only while the connection screen is foregrounded, honors the provider's interval (at least five seconds), and backs off after failures or rate limits.

Both providers retain an optional **Use website sign-in instead** flow with isolated WebKit profiles. In that ChatGPT website flow, its bearer remains inside the browser's isolated JavaScript world. No credentials are written into widget snapshots, logs, or account JSON. No inference requests are made. Native OAuth sessions bind one authorized workspace; add another connection to authorize a different account/workspace. A changed identity or workspace during token refresh is rejected.

These are integrations with undocumented provider website interfaces, not general public subscription-statistics APIs. Availability depends on the account and provider. Interactive sign-in, verification, or browser challenges must be completed by the user. Real-account sign-in and metric retrieval require account-specific validation; parser and simulated-transport tests do not establish provider availability.

The OAuth protocol details and nested Claude model-limit format were checked against [Usage4Claude](https://github.com/f-is-h/Usage4Claude), with the Codex device protocol checked against [OpenAI's implementation](https://github.com/openai/codex/blob/main/codex-rs/login/src/device_code_auth.rs) and [official authentication documentation](https://learn.chatgpt.com/docs/auth). Headroom is an independent integration using the public Claude Code and Codex clients, rather than separately registered Headroom OAuth applications. Website connection diagnostics contain only fixed operation/result labels, HTTP status, format classification, and numeric WebKit error codes, with no raw provider responses.

## Refresh and limits

Headroom refreshes connected accounts on foreground activation and every minute while open. Pull to refresh or refresh an individual account. Requests are limited to two accounts at a time, deduplicated, and backed off after errors or rate limits. Failures retain original readings and their capture times. Changed account/workspace identities are rejected. Removing an account cancels pending publication and clears that account's Keychain credential and browser profile.

The dashboard shows provider-reported session, weekly, and additional model windows, with their actual durations and reset times. Unreported quota windows and empty model-limit sections are omitted. Live overview summarizes weekly usage in medium and all reported account windows in large, using actual window labels. Unknown fields never become zero. Quota percentages are never converted into exact token totals. Claude can expose shared chat/Claude Code pools; ChatGPT collection currently covers its reported Codex allowance, not every ChatGPT chat feature.

Native Claude and ChatGPT/Codex connections can refresh while Headroom is closed using iOS Background App Refresh. The app registers a `BGAppRefreshTask` during launch and immediately requests the next available opportunity with **no added delay** (`earliestBeginDate = nil`), without waiting for a foreground screen. It queues the next opportunity when iOS delivers the task. Registration and submission failures remain visible instead of claiming the task is scheduled; Settings shows the last successful scheduling time and background result. iOS chooses when it runs; this does not guarantee a one-minute, fifteen-minute, or any fixed background interval. Enable Background App Refresh in iPhone Settings, leave Low Power Mode off, and avoid force-quitting Headroom for automatic updates. Website-only connections still need the app open.

The **Live overview** Home Screen widget reads all saved accounts directly without account configuration, including for its initial display. It is the only widget offered, in medium and large sizes. The old Account allowance and Accounts overview widgets and their Lock Screen variants have been removed. Readings retain their original ages and reset states. Home Screen widgets offer a **Refresh** button for native connections: an App Intent checks the selected accounts directly in its background process without bringing the app UI forward. Since version 0.6.0, scheduled widget timelines also fetch providers directly instead of only reloading old snapshots. Access and refresh credentials remain encrypted in the existing signed App Group’s Keychain, shared only by Headroom and its widget; they are never placed in snapshot files. Existing app-only credentials migrate after a successful secure copy. Successful reads publish a new snapshot; failed reads preserve old values and timestamps. Each account has a cross-process lock, a one-minute request cooldown, and longer persisted backoff when the provider asks. Automatic background work and widget actions have a bounded execution budget. WidgetKit is asked for the next timeline in five minutes, and fetches accounts that are due when it runs. iOS controls delivery, so neither five-minute nor continuous refresh is guaranteed. The widget shows when readings need refresh or a check failed. The app Overview, Settings → About, and Home Screen widgets display their version/build so archived widget views can be distinguished from current ones. Settings → About also shows the latest widget read when available. App and widget snapshot writes are coordinated and preserve newer readings; deleted or reconnected accounts reject late responses. Widget upgrades invalidate archived views. At the owner’s request, version 0.5.2 removes widget privacy masking, the lock gate, and alias/value hiding options; saved names and quota readings display directly. If a retired demo layout remains cached, remove only that Home Screen widget and add Headroom → Live overview again; connected accounts stay in the app.

## Build and install

Open [Headroom.xcodeproj](Headroom.xcodeproj) in Xcode. Minimum iOS version: 17.0. The project records the current owner's Personal Team for the app and widget. Select your own team if building for another account; both targets must use the same registered App Group.

```sh
xcodegen generate
xcodebuild -project Headroom.xcodeproj -scheme Headroom \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The app icon uses three rounded capacity meters in terracotta, apricot, and amber on a warm ivory background. Production artwork is in `Headroom/Assets.xcassets/AppIcon.appiconset`; the current master and exact generation prompt are `Design/AppIcon/Headroom-warm-meters-master.png` and `Design/AppIcon/generation-prompt-v2.txt`. The previous rings concept is retained in that folder as design history.

- [Native build and device verification](docs/native-build.md)
- [Feasibility analysis](docs/feasibility.md)
- [Product and iOS architecture](docs/app-design.md)
- [Widget design](docs/widgets.md)
