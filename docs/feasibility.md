# Standalone iOS feasibility analysis

> Implementation update (October 20, 2026, version 0.5): Real Claude and ChatGPT/Codex usage retrieval was confirmed by the owner. Native per-account OAuth credentials now support opportunistic Background App Refresh with no app-imposed scheduling delay, plus a Home Screen widget Refresh intent. Foreground checks run every minute; per-account cooldowns and provider backoff remain enforced. iOS controls automatic delivery, so no fixed background frequency is promised. Website-only connections require foreground collection. Exact all-product token totals remain unavailable. See native-build.md for the distinction between automated verification and device observations.

Research date: October 15, 2026, America/Los_Angeles.

## Scope and decision

The user requires an independent iPhone app for their own Claude and ChatGPT accounts, covering chat applications and coding tools. Multiple accounts per provider are required. No desktop helper, remote collector, CLI service, or required hosted backend belongs in this design.

Proceed with an **on-device subscription quota tracker**, subject to validating each provider's authentication and reporting interface on iOS. Automatic direct sync is the primary product goal. A manual dashboard alone would not establish that this goal is feasible.

Fetching server-reported quota does not inherently require a desktop process. The earlier proposal coupled this with desktop token telemetry; that dependency is removed. Reading historical local Claude Code/Codex logs from another machine is outside the standalone app's capabilities. The iPhone can still display a server-reported allowance that reflects coding activity when the provider defines a shared pool.

## What the app can measure

| Measurement | Standalone assessment |
| --- | --- |
| Several Claude and ChatGPT accounts | Feasible with separate account identities, web profiles, credentials, and usage snapshots |
| Current quota percentages and reset times | Direct network collection is a plausible implementation; actual iOS sign-in, scope, and endpoint access remain integration gates |
| Claude usage across chat and Claude Code | A server-reported shared quota can cover both; it does not establish separate chat/code token totals |
| ChatGPT/Codex allowance | Display only returned, identified product/workspace buckets; do not equate a Codex bucket with every ChatGPT feature |
| Exact tokens for every web/mobile/coding interaction | Not established by the reporting interfaces reviewed; optional only when an accessible source actually returns counts and coverage |
| Desktop-only session/log detail | Not independently accessible from this app; no desktop dependency will be added to recover it |
| Saved quota history and reminders | Feasible locally; observations begin when the app captures data |
| Fixed-interval background polling | Not guaranteed by iOS; refresh on launch/user action and use background opportunities when eligible |

Claude documents shared usage limits across product surfaces. OpenAI documents account reporting through its local app server, but that is evidence of available service data rather than an iOS reporting SDK. [Claude limits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work), [Codex app server](https://learn.chatgpt.com/docs/app-server).

Tokens, subscription quota, credits, and charges are different quantities. Never convert a percentage into remaining tokens or price subscription usage using API list prices. API/admin dashboards do not automatically expose personal subscription allowance. [OpenAI pricing](https://learn.chatgpt.com/docs/pricing), [Anthropic reporting](https://platform.claude.com/docs/en/manage-claude/usage-cost-api).

## Direct collection routes

### Preferred: documented authorization and reporting

Use an official native/public-client flow and usage-read interface where the provider documents them for this purpose. Verify client eligibility, iOS callbacks, scopes, account/workspace identity, renewal, and the exact fields returned.

Sign in with ChatGPT exists, but its documented identity and optional inference capabilities are not a general grant to read subscription statistics or conversations. Do not infer usage-read permission from a successful login. The previously identified app-server methods will not be deployed as a local or remote service for this app. [SIWC quickstart](https://developers.openai.com/siwc/quickstart).

### Practical personal-app candidate: provider web sessions on the iPhone

The app can own a distinct authenticated web profile for each account and investigate the usage resources used by the provider's website. Existing implementations demonstrate network-based quota collection without deriving it from local token logs:

- Claude: CodexBar documents account/organization discovery and `claude.ai/api/organizations/{orgId}/usage` using a web session.
- ChatGPT/Codex: CodexBar documents a direct `chatgpt.com/backend-api/wham/usage` request with account-scoped authentication, as well as a web dashboard strategy.

These are undocumented integration candidates, not provider-supported iOS contracts. Desktop implementation evidence does not prove that an iPhone can acquire or renew the necessary session. In particular, a web cookie is not interchangeable with an OAuth bearer token, and a sign-in token may have the wrong audience or scope for a usage endpoint. [Claude implementation evidence](https://github.com/steipete/CodexBar/blob/main/docs/claude.md), [Codex implementation evidence](https://github.com/steipete/CodexBar/blob/main/docs/codex.md).

For web collection, prefer fetching same-origin usage data within the account's own WebKit session, returning only normalized metrics to native code. Use native `URLSession` only after validating a legitimate compatible authentication path with isolated per-account storage. Do not assume cookies copied from a web view will be sufficient.

Apple supports separate persistent WebKit data stores identified by UUID. This isolates this app's profiles; it does not provide access to Safari or the official providers' apps. Embedded Google/provider sign-in and challenge handling must be tested. A system-browser login does not automatically populate a WebKit cookie store. [WebKit data stores](https://developer.apple.com/documentation/webkit/wkwebsitedatastore).

Stop collection at interactive challenges and show the account's sign-in/usage page. Do not disguise the app as a first-party client or bypass access controls. Personal use is not, by itself, evidence of provider permission for a private interface. [Claude authentication guidance](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account).

### Optional iPhone-only capture extension

If a provider does not work in an app-owned web profile, an optional Safari web extension packaged with the iOS app could capture a usage page that the user opens in Safari. A content script would send metrics through the extension background script and native extension into an App Group store, with verified account and Safari profile binding.

This remains entirely on the iPhone. It is a user-initiated browser capture route, not proof of unattended refresh from the native app. Apple documents that the containing iOS app cannot initiate messages to extension JavaScript. This option is not a required component of the first design. [Apple extension messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension).

### Fallback: screenshot capture and manual readings

An iOS share extension or photo picker can accept a provider usage screenshot. On-device Vision OCR suggests percentage/reset values; the user confirms account, workspace, window, observation time, and parsed values before saving. Manual entry uses the same confirmation model.

This is independent and useful but does not fulfill automatic sync. If both direct routes fail, report that limitation before proceeding with a reduced manual-only product. Never label imported images as live provider data or infer hidden tokens from a screenshot.

## iOS execution and data constraints

- A foreground app can issue direct HTTPS requests and use its own authenticated web sessions. The collection path remains on the phone.
- iOS chooses background task execution times. Opportunistic refresh and reset reminders are feasible; continuous polling and immediate threshold alerts are not guaranteed. [Apple background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app).
- A native background task cannot assume a suspended WebKit page is available. Background HTTP collection is enabled only for an adapter with a validated native credential path; otherwise update when the app is open.
- Credentials remain in the phone's appropriate protected stores: Keychain for app-owned OAuth secrets, WebKit's store for web-session data. They are not written to SwiftData, exports, analytics, or logs.
- All history is local. Cloud sync and a hosted collector are not prerequisites.
- No API key or model inference request should be required merely to inspect subscription usage.

## Standalone validation gate

### Widgets without opening the app

Home Screen and Lock Screen widgets are part of the first release. WidgetKit can render saved account readings without launching Headroom and can make network requests when its extension runs. This supports a direct on-iPhone refresh path without a server, provided the adapter has suitable native authentication. [Apple widget networking](https://developer.apple.com/documentation/widgetkit/making-network-requests-in-a-widget-extension).

There are two separate acceptance levels:

- **Glanceable display:** a widget shows the latest saved reading, its account/window, and observation age even while the app is closed. Feasible regardless of the original foreground collection method.
- **Fresh independent updates:** the widget extension reads the provider directly using a validated native adapter and shared protected credential access. This must be tested per provider. A foreground WebKit login/read does not establish this capability, and saved snapshots alone do not fulfill automatic freshness.

The system schedules widget reloads; neither automatic refresh nor an interactive refresh can guarantee that a provider request succeeds. Background runtime, networking, credential availability, expiry, and rate limits still apply. Use local timeline entries for expected-reset and stale-state changes, keeping the original measured percentage until a real observation replaces it. [Apple widget timelines](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

The detailed requirements and native architecture are in [widgets.md](widgets.md). A provider adapter should not pass the full widget freshness gate until it can update while the containing app is not open.

### Provider and widget proof

Timebox an initial spike to approximately 2–4 developer days; authentication friction may extend it. These are planning estimates, not completed tests.

1. On an iPhone/simulator, create a persistent isolated profile and complete a real provider login. Include email and any intended social sign-in flow. Test callback/session ownership rather than assuming Safari login transfers.
2. Read a real usage response/page directly on the phone. Record authentication type and reporting scope without logging credentials.
3. Verify quota/reset values against the provider UI. Establish which chat/coding activity each pool covers and whether token counts exist at all.
4. Add a second account for the same provider. Relaunch and refresh both; confirm identity and workspace isolation. Repeat for the other provider.
5. Exercise session expiry/renewal, sign-out, app termination, locked-device access, offline refresh, rate limiting, and interactive challenges.
6. Verify any native background path separately. A foreground WebKit read does not establish background support.
7. Produce a per-provider result: foreground sync, background eligibility, identity support, quota fields, token fields/coverage, renewal behavior, and source support level.
8. Add a Home Screen widget and update a reading from its native timeline/refresh path while Headroom is not open. Verify original timestamps, account isolation, missing/revoked credentials, Lock Screen redaction, and state after an expected reset. Test without Xcode's debugger; debug reload behavior is not representative of release scheduling.

Go: an on-device collector can authenticate, retain separate accounts, and read subscription quota reliably enough for personal use.

Conditional: one provider works automatically and another requires browser capture or manual fallback. Make reduced coverage explicit; do not silently treat it as the original goal being complete.

Not established: exact all-device token totals, complete ordinary-chat coverage from a Codex bucket, uninterrupted background updates, or App Store approval.

A native SwiftUI prototype and WidgetKit extension are now available in `Headroom.xcodeproj`. They demonstrate sample/manual readings and widgets; live provider integration remains unimplemented. See [native build notes](native-build.md).
