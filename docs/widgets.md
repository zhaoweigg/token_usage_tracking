# Headroom widgets

As of version 0.5.5 (10), **Live overview** is the only widget. The owner confirmed that it displays their real accounts on the iPhone. Account allowance, the older Accounts overview, their account/model configuration intents, and their small/Lock Screen variants have been removed at the owner’s request.

## Layouts

| Size | Content |
| --- | --- |
| Medium | Up to four saved accounts, weekly usage when reported (otherwise an available account window), actual window labels, and each reading’s age |
| Large | Up to four saved accounts with all reported account-wide windows and their ages |

Both sizes include the widget version/build and a Refresh button for native connections. Additional accounts are indicated with an open-app hint. Account model limits remain available in the app’s cards/details. The in-app gallery previews only these two Live overview sizes.

The widget kind remains `HeadroomLiveOverview`, so an existing working Live overview keeps its identity across this update. Old removed widgets may need to be removed from the Home Screen if iOS leaves their archived views in place; connected accounts are unaffected.

## Saved-data path

`StaticConfiguration` and `LiveOverviewProvider` read the App Group snapshot synchronously for placeholder, snapshot, and timeline requests. The widget always covers all saved accounts and has no account-entity configuration dependency. No sample data is substituted.

A ready snapshot renders directly, including under host placeholder/privacy styling, following the owner’s request to remove hiding. An empty snapshot shows Connect an account. A missing/unreadable snapshot reports Saved usage unavailable. Missing quota windows and empty model sections do not produce fake zero readings. Original observation times remain visible; passed resets await new provider readings.

The containing app alone writes provider snapshots atomically. The widget extension reads them and contains no provider credentials. Access/refresh credentials stay in the app’s Keychain. Widget-read diagnostics contain only time, fixed kind/phase/state labels, version, and account count. Settings → About shows the latest read details when available.

## Refresh

The Home Screen button invokes `RefreshUsageIntent` in the containing app process without bringing up the app’s UI. Native account reads are deduplicated and honor one-minute cooldowns and longer provider backoff. Successful captures publish a snapshot and reload only `HeadroomLiveOverview`; errors preserve old values and observation times. Account deletion and credential rotation keep the same account/generation binding checks as app refresh.

Background App Refresh requests the next available OS opportunity with no app-imposed delay. It is not a fixed-interval guarantee. Foreground checks run every minute. WidgetKit timeline reloads are requested around 30 minutes for presentation updates; these are separate from provider requests. Timeline entries also reflect stale/reset boundaries without inventing measurements.

The app Overview, Settings → About, and Home Screen widget footer expose version/build numbers so archived displays can be identified. The 0.5.4 widget extension was confirmed to read two saved accounts on the physical iPhone, and the owner subsequently confirmed the Live overview works. The current build’s validation is recorded in native-build.md.
