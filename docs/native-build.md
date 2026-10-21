# Native app and simulator verification

## Launch-time background task scheduling (October 20, 2026)

Version **0.6.1 build 12** keeps the existing `BGAppRefreshTask` registration and queues its first request during app launch, without waiting for a foreground scene. Registration runs only once per process; requests cannot be submitted before successful registration. The OS launch handler already queues the next opportunity, and account changes/background transitions maintain the schedule. Settings now shows the last successful scheduling time separately from the last completed background check and does not report an unregistered task as scheduled. The existing `fetch` background mode and permitted identifier `com.example.headroom.refresh` remain configured. iOS still controls actual delivery; no fixed interval is guaranteed.

All **62 tests** (57 unit/integration and 5 UI) passed with zero failures or skips on iPhone 17 Pro Simulator, iOS 26.5. Scheduling coverage now verifies startup registration before submission, one-time registration and request deduplication, failure without false scheduled status, and successful submission retry without another registration. Results: `.build/BackgroundRegistration-20261020.xcresult`, `.build/background-registration-summary-20261020.json`, and `.build/background-registration-tests-20261020.log`. The signed generic iPhone build succeeded in `.build/background-registration-generic-iphone-build-20261020.log`; the initial device-specific build could not start while Xcode waited to reconnect to the phone.

Version **0.6.1 (12)** subsequently installed and launched on the connected iPhone. A sanitized app-preference check confirmed successful registration, available system background refresh, Low Power Mode off, and a successful request at **2026-10-21 00:25:07 UTC** (October 20, 17:25 PDT). The background toggle had no saved override and therefore retained its enabled default. No background execution had yet been recorded; this verifies accepted registration/submission rather than natural OS delivery. The temporary preference copy was deleted. Device results: `.build/background-registration-install-20261020.json` and `.build/background-registration-launch-20261020.json`.

## Direct widget refresh (October 20, 2026)

Version **0.6.0 build 11** fixes stale Home Screen readings by fetching provider usage directly from both scheduled widget timelines and the Refresh App Intent. The prior widget timeline only read saved snapshots, and the inspected device metadata showed no completed app background run. The app's separate Background App Refresh path remains available; widget collection no longer depends on it running.

The app and extension share the existing signed App Group's Keychain. Opening the updated app migrates each existing native sign-in only after successfully saving its credential in that protected group. Credentials never enter snapshots or diagnostic files. Per-account cross-process locks serialize requests and token renewal, persisted retry metadata enforces cooldowns/provider backoff, and snapshot transactions preserve newer readings. Deleted or reconnected accounts reject late responses. Refresh work has a 22-second deadline; automatic widget checks request another timeline after five minutes, with actual delivery controlled by iOS. Manual refresh reports its outcome and preserves the original capture time on failure or cooldown.

All **60 tests** (55 unit/integration and 5 UI) passed with zero failures or skips on iPhone 17 Pro Simulator, iOS 26.5. New coverage verifies direct widget collection, concurrent app/widget request deduplication, deletion/reconnection during a request, shared rate-limit backoff, deadline cancellation, private-to-shared Keychain migration, and automatic-off/manual-on behavior. Synthetic test snapshots disable real provider networking. Results: `.build/DirectWidgetFetchVerified-20261020.xcresult`, `.build/direct-widget-fetch-verified-summary-20261020.json`, and `.build/direct-widget-fetch-verified-tests-20261020.log`.

The physical-device build succeeded and **0.6.0 (11)** installed on the owner's iPhone. Remote launch was blocked by the device lock, so the owner opened the app manually to migrate sign-ins, returned to the Home Screen, and confirmed that the widget refreshes there. This verifies on-demand real-account widget collection; it does not establish a guaranteed automatic interval. Device build: `.build/direct-widget-fetch-verified-iphone-build-20261020.log`.

## Live overview only (October 20, 2026)

The owner confirmed that Live overview works with their real accounts and requested removal of the allowance widgets. Version 0.5.5 build 10 keeps only **Live overview**, with medium/large sizes and the existing `HeadroomLiveOverview` kind. Account allowance, older Accounts overview, their account/model configuration intents, small and Lock Screen variants, and obsolete shared renderers were removed. The in-app gallery now previews only Live overview and its two sizes. Reloads/diagnostics target only the retained kind; the working widget’s saved identity is preserved.

All 52 current tests (47 unit/integration and 5 UI) passed on iPhone 17 Pro Simulator, iOS 26.5, with zero failures. One obsolete account-selection unit test was removed with its deleted configuration code. UI checks now verify the Live overview gallery, version visibility, no legacy widget choices, and no host-redaction loading/lock gate. Results: `.build/LiveWidgetsOnly-20261020.xcresult` and `.build/live-widgets-only-tests-20261020.log`. The physical-device build succeeded and installed; device build: `.build/live-widgets-only-iphone-build-20261020.log`. The subsequent automatic launch failed when the CoreDevice tunnel disconnected; the installed update can be opened manually.

## Visible versions and direct saved-data widget (October 20, 2026)

Version 0.5.4 build 9 adds the app version/build to Overview and Settings → About, and the extension’s version/build to Home Screen widget footers. Both built Info.plist files were checked to contain 0.5.4 / 9. Settings About can also report the latest widget load time, widget version, and number of accounts read. These diagnostics contain only time, fixed kind/phase/state labels, version, and account count.

The ready-state widget view no longer treats an inherited `.placeholder` redaction reason as evidence that data has not loaded. It displays its resolved content unmasked, as requested by the owner. A new **Live overview** kind uses `StaticConfiguration` and synchronous shared-snapshot reads for placeholder, snapshot, and timeline phases; it always covers all saved accounts and does not resolve account configuration entities. Existing configurable kinds remain available. All three kinds reload after app/background/intent publication.

The first full Simulator run passed all 48 unit/integration tests and 4 UI tests. The remaining UI test failed only to find a version footer by identifier; querying its visible text passed in the focused rerun. The screenshot was exported and inspected to confirm **v0.5.4 (9)** is visibly rendered, with no loading/lock substitution under forced privacy and placeholder styling. Thus all 53 distinct tests have passing results across the full run and focused rerun. Results: `.build/WidgetVersionAndLiveOverview-20261020.xcresult`, `.build/WidgetVersionVisibility-20261020.xcresult`, and corresponding `widget-version-live-tests-20261020.log` / `widget-version-visibility-tests-20261020.log`. The inspected screenshot is `.build/widget-version-verified-screenshots/E48AA60F-E5AC-407B-B6CE-6331B9300767.png`.

The physical build succeeded, installed, and launched. A sanitized app-preference check found cache build 9, two saved accounts, and a **HeadroomLiveOverview** extension report at version 0.5.4 (9), phase Placeholder, with two accounts and ready state. This confirms the extension can read the real shared snapshot on the iPhone. It does not establish the final Home Screen display or on-demand network refresh; the owner subsequently confirmed that Live overview works. The temporary device preference copy was deleted. Build/launch logs: `.build/widget-version-live-iphone-build-20261020.log` and `.build/widget-version-live-launch-20261020.json`.

## Unreported quota rows removed (October 20, 2026)

Version 0.5.3 build 8 omits account quota windows without a usable saved reading in Overview, account details, and multi-window widgets. This removes the empty Session / Not available / Never row for weekly-only Codex accounts. Real zero readings, stale observations, and passed-reset observations are retained. Empty model-limit sections/messages are omitted. Single-window widgets use a reported account window when their preferred window is missing and show that window’s actual label; compact overview rows label their own windows.

All 53 existing tests (48 unit/integration and 5 UI) passed on iPhone 17 Pro Simulator, iOS 26.5. Results: `.build/ReportedLimitsOnly-20261020.xcresult` and `.build/reported-limits-tests-20261020.log`. The physical-device build succeeded, installed, and launched on the connected iPhone. Device logs: `.build/reported-limits-iphone-build-20261020.log` and `.build/reported-limits-launch-20261020.json`.

## Widget hiding removed (October 20, 2026)

At the owner’s explicit request, version 0.5.2 build 7 removes the widget privacy gate, widget `privacySensitive` modifiers, and hide-alias/hide-value controls and parameters. The earlier “Unlock for usage” message incorrectly interpreted a privacy redaction reason as a reliable device-lock signal; it is no longer emitted. Saved labels and quota values display directly. Loading, unavailable snapshot, removed-selection, and unknown/reset-awaiting-update states remain factual data states.

All 53 tests (48 unit/integration, 5 UI) passed on iPhone 17 Pro Simulator, iOS 26.5. The replacement regression check forces a privacy redaction environment and verifies widget content remains available with no lock gate or hiding controls. Results: `.build/WidgetNoHiding-20261020.xcresult` and `.build/widget-no-hiding-tests-20261020.log`. The physical-device build succeeded, installed, and launched on the connected iPhone; logs: `.build/widget-no-hiding-iphone-build-20261020.log` and `.build/widget-no-hiding-launch-20261020.json`. Direct observation of the owner’s refreshed widget remains separate from these checks.

## Widget saved-data fix (October 20, 2026)

Version 0.5.1 build 6 passed all 53 tests (48 unit/integration and 5 UI) with zero failures on iPhone 17 Pro Simulator, iOS 26.5. The physical-device build succeeded, installed, and launched on the connected iPhone. Results: `.build/WidgetDataFinal-20261020.xcresult` and `.build/widget-data-final-tests-20261020.log`; device build: `.build/widget-data-final-iphone-build-20261020.log`.

The reported four-row widget screenshot matches the retired demo readings (84/52, 31/24, 48/73, and unavailable) with text redacted. Current snapshot decoding removes those seeded records. Version 0.5.1 requests a one-time reload of all widget timelines after publishing clean data on upgrade, displays explicit privacy/loading/unreadable-data states without quota bars, and distinguishes missing selected accounts from an empty snapshot. A new unconfigured account widget can use the first saved account; an explicitly removed selection never silently retargets another account. Account/model queries retain removed IDs as unavailable entities so WidgetKit can resolve old configurations and render the repair state. A sanitized device preference check confirmed cache generation 6 and fresh readings for both connected accounts after launch; the temporary metadata copy was deleted. Regression tests verify mixed legacy/live snapshot filtering, original provider values and timestamps, missing/corrupt snapshot states, stable selection behavior, and the visible privacy explanation.

The automated tests do not establish that iOS discarded the owner’s archived Home Screen view. A final visual inspection was blocked when the Mac locked; on-device widget confirmation remains pending. If an old four-row view persists after opening the updated app while unlocked, remove only that widget and add **Headroom → Accounts overview** again. This does not remove connected accounts.

## Background refresh update (October 20, 2026)

Version 0.5.0 build 5 passed all 49 tests (45 unit/integration and 4 UI) with zero failures on iPhone 17 Pro Simulator, iOS 26.5. The physical iPhone build succeeded, installed, and launched on the connected iPhone. A sanitized check of app-owned metadata confirmed both native OAuth accounts remained connected and received new readings after launch; the temporary metadata copy was deleted. Results: `.build/BackgroundRefreshFinal-20261020.xcresult`, `.build/background-final-tests-20261020.log`, and `.build/background-final-iphone-build-20261020.log`.

The new tests cover native-only background eligibility, widget account selection, one-minute cooldowns, persisted provider backoff, cancellation without late publication, foreground/background isolation, expiration completion exactly once, scheduling with a nil earliest date, and the persistent background-refresh setting. The native clients are shared with the previously confirmed live provider reads. These tests do not establish natural iOS scheduling frequency or a successful end-to-end Home Screen button invocation on the owner's device.

Background App Refresh requests the next available OS opportunity with no additional delay. It is not a fixed-interval timer. Home Screen widget Refresh uses an App Intent routed to the containing app without foreground UI, keeping credentials outside the extension. Both paths use a 22-second work deadline, preserve old observations on failure, and honor account cooldowns/backoff. Website-only sessions remain foreground-only. Headroom Settings reports availability and the last background outcome. Lock Screen widgets remain glanceable cached views.

## Current connection implementation (October 20, 2026)

Production starts empty and removes the old seeded demo accounts. Claude defaults to system-browser authorization using the public Claude Code PKCE client and `user:profile`, following Usage4Claude. The iOS return step accepts the complete code from Claude's HTTPS callback page, validates state and expiry, and then reads profile/usage directly. ChatGPT now defaults to Codex device authorization in the system browser, with a PKCE browser return-link fallback. Both providers save per-account access/refresh credentials only in the iPhone Keychain. Refresh rotation is saved for the originating account; deleting an account deletes its credential. Isolated WebKit sign-in remains an optional fallback for both providers. No Mac companion or local callback listener is used.

Version 0.4.0 build 4 passed all 41 tests (38 unit/integration and 3 UI), with zero failures, on iPhone 17 Pro Simulator running iOS 26.5. Coverage includes device approval pending/success/expiry/rate limits, callback state/host/port validation, credential rotation, account/workspace binding, deletion during refresh, Keychain isolation, and credential-free metadata persistence. The physical-device build succeeded; the app and widget installed, and Headroom launched on the owner's connected iPhone. The existing Claude account was confirmed to have saved provider session, weekly, and model readings before this update. The owner subsequently confirmed that real ChatGPT/Codex usage limits loaded on the iPhone. Live usage retrieval is now confirmed for both providers; this does not independently verify every returned model pool, later credential renewal, multiple simultaneous accounts, or background widget updates.

Version 0.4 results: `.build/CodexOAuthTests-20261020.xcresult` and `.build/codex-oauth-summary-20261020.json`. Device build and launch: `.build/codex-oauth-iphone-build-20261020.log` and `.build/codex-oauth-iphone-launch-20261020.json`.

The physical-device failure screenshot showed Google's passkey flow still on `accounts.google.com`, before Claude authentication completed. After installing the system-browser route, the owner confirmed that real Claude usage limits loaded on the iPhone. Simulator tests use synthetic credentials and mock responses; they do not prove provider availability. That version displayed saved widget snapshots; version 0.5 adds the native background and widget refresh paths described above.

The previous 0.2 build passed 22 tests and installed/launched on the physical iPhone. The 0.3 connection changes add native OAuth/Keychain tests, actual WebKit isolated-world transport checks, nested model-limit parsing, and safe diagnostic handling. The final 0.3 code passed 33 tests (30 unit/integration and 3 UI), with zero failures and zero skips, on iPhone 17 Pro Simulator running iOS 26.5. The physical-device Debug build succeeded and version 0.3.0 build 3 installed on the connected iPhone. The owner then confirmed successful live Claude readings.

Final results: `.build/ClaudeOAuthFinal-20261020.xcresult` and `.build/claude-oauth-final-summary-20261020.json`. Device build log: `.build/claude-oauth-iphone-build-20261020.log`. The earlier 0.2 installation and historical prototype verification below are retained as history.

## Implemented

- SwiftUI Overview, Activity, Accounts, account detail, manual entry, settings, and native widget previews.
- Several independent accounts per provider, local Codable persistence, per-window observations, and quota history filtered by window.
- Empty initial state and removal of legacy demo readings; unavailable tokens remain unavailable. Refresh does not fabricate a new reading.
- A separate WidgetKit extension with small/medium/large Home Screen widgets and rectangular/circular Lock Screen widgets.
- App Intent account/window configuration, original observation times, reset-awaiting-update handling, App Group snapshot sharing, and safe account deep links.
- Removal confirmation and widget updates after local changes.
- Weekly progress bars alongside short-window bars in Overview and account details, including accounts with no short-window reading.
- Optional model/model-group limits with independent window labels, resets, observation times, percentages, and reported message/token/request counts. Model limits are not added together or inferred from a plan name.
- Manual creation/update of model limits and separate model history. Older saved accounts decode with no model limits and preserve their existing readings.
- Medium/large account widgets with weekly and model bars; configurable model focus for individual widgets. Model choices carry account identity and cannot fall back to another account's reading.

Not implemented: remote token collection, screenshot OCR, or notification scheduling. Authentication/network collection are implemented as described above, with successful live usage retrieval confirmed by the owner for both Claude and ChatGPT/Codex on October 20, 2026. The app does not use API keys or send inference requests.

## Standard build

The checked-in Xcode project is generated from `project.yml` using XcodeGen 2.45.3. Regenerate after changing target/project configuration:

```sh
xcodegen generate
```

Open `Headroom.xcodeproj`, choose the `Headroom` scheme and an iPhone simulator, then Run. The `Headroom` test action includes model, provider-transport, OAuth, Keychain, and UI tests. On a physical device, configure a development team and a registered shared App Group for both targets.

```sh
scripts/run-simulator.sh SIMULATOR_UDID
```

## Xcode setup (resolved October 16, 2026)

The earlier environment had Xcode 26.5 (17F42) paired with older system developer components. Normal builds failed loading `IDESimulatorFoundation`, and `xcodebuild -checkFirstLaunchStatus` returned 69. The locked Mac prevented completing the component installer.

After the Mac was unlocked, first-launch validation passed. Apple's iOS 26.5 platform download completed and the runtime registered successfully. Xcode now recognizes both iOS 26.3.1 and 26.5 simulator destinations. The app, widget extension, unit-test target, and UI-test target compiled and signed through the standard Xcode build, and the resulting app installed and launched on the iPhone 17 Pro simulator. No system framework or Xcode binary was manually modified.

Initial XCTest attempts waited in install/launch setup. Restarting Xcode, Simulator, and the simulator service after platform installation resolved that startup issue. A standard Xcode run on iOS 26.5 then passed all ten unit tests and both UI tests with zero failures. The normal debugger-enabled scheme is restored; no diagnostic debugger setting remains in `project.yml`.

Successful command and result bundle:

```sh
xcodebuild -project Headroom.xcodeproj -scheme Headroom -configuration Debug \
  -destination 'platform=iOS Simulator,id=20E63AE6-36C3-4BC1-B319-06A2FDB902EC' \
  -derivedDataPath .build/DerivedData \
  -resultBundlePath .build/HeadroomTests-20261016-refreshed.xcresult \
  -parallel-testing-enabled NO test
```

UI tests use the separate `Headroom.UITests` preferences suite so test fixture resets do not replace normal local accounts.

## Physical iPhone installation (October 19, 2026)

The project now preserves the owner's Personal Team (`TXCLU6TPCW`) in `project.yml`, so both app and widget inherit the same signing team after XcodeGen regeneration. A standard Debug build for the connected physical iPhone succeeded with automatic provisioning. Both provisioning profiles include the device and `group.com.example.headroom`; the app and embedded widget signatures pass strict verification. The signed app and widget installed successfully. After the owner trusted the developer profile on the phone, Headroom launched successfully on the physical iPhone 17 Pro running iOS 27.0. A subsequent process query confirmed that Headroom remained running. Physical-device widget placement has not been verified.

Build log: `.build/iphone-install-build-20261019.log`. Profile validation: `.build/device-signing-validation-20261019.json`. Successful launch and running-process evidence: `.build/iphone-launch-20261019.json` and `.build/iphone-running-20261019.json`.

## Historical compiler fallback

To verify the native app without claiming that the normal Xcode build succeeded, `scripts/build-direct-simulator.sh` uses Xcode's unmodified Swift compiler and iPhoneSimulator SDK directly. It compiles the app/extension, extracts App Intents metadata, creates simulator bundles, and signs them ad hoc with their App Group entitlements. It also builds a small domain smoke-test executable from the same model source.

This fallback is for the current Apple Silicon simulator development environment. It is not an App Store archive workflow and does not replace a successful normal Xcode build or XCTest run.

```sh
scripts/build-direct-simulator.sh
```

Its output is `.build/Simulator/Headroom.app`. The installed CoreSimulator command-line binary can install and launch it on the existing iOS 26.3 runtime while the newer Xcode setup is incomplete.

The simulator used in this session is iPhone 17 Pro, UDID `136A5461-42FA-4B7A-AEED-E389FF1C18CB`. Screenshot output is under `.build/screenshots/`.

Native app routes useful for widget navigation and simulator inspection:

- `headroom://overview`
- `headroom://activity`
- `headroom://accounts`
- `headroom://widgets`
- `headroom://account/<saved-account-UUID>`

## Verification boundaries

Verified on October 15, 2026:

- App and WidgetKit extension compiled using Xcode 26.5's Swift compiler and simulator SDK; App Intents metadata extraction and ad-hoc signing succeeded.
- App installed and launched on iPhone 17 Pro with the iOS 26.3 simulator runtime.
- Ten model smoke checks passed inside the simulator: missing values, reset handling, stale timestamps, account/window isolation, persistence round-trip, invalid percentage handling, older-account migration, isolated model updates/history, count normalization, and model identity/reset scoping.
- The widget extension appeared in the simulator's WidgetKit plugin registry, and the app wrote its snapshot into the shared App Group container.
- Visually inspected Overview, Activity, Accounts, and the five native widget gallery previews. The medium widget keeps reading ages visible; the large widget shows age separately for each quota window; the circular widget identifies the provider and sample source.

Simulator captures: [Overview](../.build/screenshots/overview.png), [medium widget preview](../.build/screenshots/widgets.png), [large widget preview](../.build/screenshots/widget-large.png), and [Lock Screen widget preview](../.build/screenshots/widget-lock.png). These are app gallery previews, not installed Home Screen/Lock Screen widget instances.

Weekly/model limit captures: [dashboard](../.build/screenshots/limits-overview.png), [account widget](../.build/screenshots/limits-widget-medium.png), [model widget](../.build/screenshots/limits-widget-model.png), [message-count widget](../.build/screenshots/limits-widget-count.png), and [model-entry form](../.build/screenshots/limits-model-entry.png). A deliberately mismatched model/account selection was also visually checked and showed an unavailable state.

Debug builds accept `--preview-widgets` and `--preview-widget-size small|medium|large|rectangular|circular`, plus `--preview-activity` or `--preview-accounts`, to inspect native screens without a web deep-link confirmation. These flags do not fetch or change provider readings.

Additional debug inspection flags: `--preview-account UUID`, `--preview-model-reading` (with an account), `--preview-widget-account UUID`, `--preview-model-limit MODEL_LIMIT_ID`, and `--preview-widget-overview`. The gallery defaults to the account-limits layout for medium/large sizes. Sample Sonnet/Opus weekly limits and a daily reasoning-model message limit are illustrative fixtures, not current provider entitlements.

On October 16, 2026, the standard Xcode build and all 12 XCTest tests passed on iPhone 17 Pro with iOS 26.5 (device `20E63AE6-36C3-4BC1-B319-06A2FDB902EC`). The ten standalone model smoke checks also passed on that runtime. Xcode component installation and test-runner startup are resolved.

A real medium Account allowance widget was added through the system Home Screen widget gallery on that simulator. It displayed the short-window, weekly, Sonnet, and Opus bars from the shared sample snapshot after the containing app was terminated. See [installed Home Screen widget](../.build/screenshots/home-widget-20261016.png). This verifies actual WidgetKit placement/rendering, beyond the in-app previews; it does not establish live provider updates or Lock Screen placement.

The app icon was added on October 16, 2026 as an opaque 1024 × 1024 universal iOS app-icon asset. The standard Xcode build succeeded with the `AppIcon` catalog, the app installed and launched, and its icon was visually verified on the iPhone 17 Pro Home Screen. See [installed icon](../.build/screenshots/icon-home-20261016.png). Xcode's Simulator asset helper initially stalled; restarting the affected build and simulator service resolved it. No automated tests were added or rerun for this artwork-only change.

Builds, tests, and simulator rendering are distinct from live provider validation. The widget extension being registered and receiving a shared snapshot is distinct from proving automatic provider updates. The historical verification above predates the October 20 connection implementation described at the top.
