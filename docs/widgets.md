# Headroom widgets

As of version 0.6.1 (12), **Live overview** is the only widget. The owner confirmed that it displays their real accounts on the iPhone. Account allowance, the older Accounts overview, their account/model configuration intents, and their small/Lock Screen variants have been removed at the owner’s request.

## Layouts

| Size | Content |
| --- | --- |
| Medium | Up to four saved accounts, weekly usage when reported (otherwise an available account window), actual window labels, and each reading’s age |
| Large | Up to four saved accounts with all reported account-wide windows and their ages |

Both sizes include the widget version/build and a Refresh button for native connections. Additional accounts are indicated with an open-app hint. Account model limits remain available in the app’s cards/details. The in-app gallery previews only these two Live overview sizes.

The widget kind remains `HeadroomLiveOverview`, so an existing working Live overview keeps its identity across this update. Old removed widgets may need to be removed from the Home Screen if iOS leaves their archived views in place; connected accounts are unaffected.

## Saved-data path

`StaticConfiguration` and `LiveOverviewProvider` read the App Group snapshot immediately for placeholder and snapshot requests. Timeline requests first check eligible providers, then load the latest saved snapshot. The widget always covers all saved accounts and has no account-entity configuration dependency. No sample data is substituted.

A ready snapshot renders directly, including under host placeholder/privacy styling, following the owner’s request to remove hiding. An empty snapshot shows Connect an account. A missing/unreadable snapshot reports Saved usage unavailable. Missing quota windows and empty model sections do not produce fake zero readings. Original observation times remain visible; passed resets await new provider readings.

The app and widget coordinate atomic snapshot writes with a short shared-file transaction. App startup merges newer widget readings before persisting its local state, so old app preferences cannot replace fresh widget captures. Every connection has an identity/workspace binding and a generation; deletion and reconnection invalidate late responses. Access/refresh credentials stay encrypted in the existing signed App Group’s Keychain, accessible only to Headroom and its widget. Existing private items are copied successfully into that access group before their old item is removed; no credentials enter JSON snapshots. Widget-read diagnostics contain only time, fixed kind/phase/state labels, version, and account count. Settings → About shows the latest read details when available.

## Refresh

The Home Screen button invokes `RefreshUsageIntent` and performs native provider reads directly in the executing background process. It no longer relies on routing into the main app. Scheduled `getTimeline` callbacks also perform provider reads when data is due; placeholder and preview snapshots remain immediate saved-data reads. A 22-second work budget and two-account concurrency limit apply. Per-account cross-process file locks serialize credential renewal; shared retry metadata enforces one-minute cooldowns and longer provider backoff. Successful captures publish a snapshot and reload only `HeadroomLiveOverview`; errors preserve old values and observation times. Account deletion and credential rotation keep the same account/generation binding checks as app refresh.

Background App Refresh registers during app launch and immediately requests the next available OS opportunity with no app-imposed delay, even without a foreground scene. The next request is queued when the OS delivers the task. Settings reports submission failures and the last successful scheduling time. It is not a fixed-interval guarantee. Foreground checks run every minute. WidgetKit timeline reloads are requested after five minutes. When delivered, the provider checks eligible native accounts whose last capture is at least five minutes old. Actual scheduling remains controlled by iOS, with no fixed-interval promise. Turning automatic background refresh off also disables scheduled widget fetching; the manual button remains available. Timeline entries also reflect stale/reset boundaries without inventing measurements.

The app Overview, Settings → About, and Home Screen widget footer expose version/build numbers so archived displays can be identified. The owner confirmed that version 0.6.0 refreshes real readings while staying on the Home Screen after opening the updated app once to migrate sign-ins. Test snapshots disable real provider networking so synthetic fixtures cannot leak into live requests. The current build’s validation is recorded in native-build.md.
