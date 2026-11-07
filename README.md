# StepsBridge

Pulls your daily step totals from **Google Health** (the service your fitness band syncs
to) and writes them into **Apple Health**, replacing the "Fitness Data Sync" app whose
access broke when Google shut off the old Fitbit Web API (Nov 2, 2026).

Built against Google's current **Google Health API** (the official replacement for the
retired Fitbit Web API) — see <https://developers.google.com/health/about>.

## What this is / isn't

- This is **source code only**. It was written in a Linux cloud container with no Xcode,
  so it has not been compiled or run. You'll need a Mac with Xcode to build and install it.
- It's built for **personal, single-user use**. The Google OAuth client stays in
  "Testing" mode (your own Google account added as a test user) so you skip Google's
  formal security/privacy review, which is meant for apps with real public user bases.
  The tradeoff: in Testing mode, Google refresh tokens expire after ~7 days, so you'll
  need to tap "Connect Google Health" again roughly once a week.
- Sync is **manual** (a "Sync Now" button), matching how you already use the Google
  Health app. It pulls the last 14 trailing days each time, so missing a day or two
  doesn't lose data.

## 1. Google Cloud setup (one-time, ~10 minutes)

1. Go to <https://console.cloud.google.com/> and create a new project (e.g. "StepsBridge").
2. Enable the **Google Health API** for that project:
   <https://console.cloud.google.com/apis/library> → search "Google Health API" → Enable.
3. Configure the **OAuth consent screen** (APIs & Services → OAuth consent screen):
   - User type: External.
   - Leave **Publishing status: Testing**. Do NOT publish/verify the app — that triggers
     Google's restricted-scope security review, which isn't worth it for personal use.
   - Under **Audience → Test users**, add your own Google account email.
   - Under **Data access**, click "Add or remove scopes" and, under "Manually add scopes",
     paste these four (one per line), then Add to table → Update → Save:
     ```
     https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly
     https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly
     https://www.googleapis.com/auth/googlehealth.sleep.readonly
     https://www.googleapis.com/auth/googlehealth.nutrition.readonly
     ```
4. Create the **OAuth client ID** (APIs & Services → Credentials → Create Credentials →
   OAuth client ID):
   - **Recommended: Application type = iOS**, Bundle ID = `com.yanivbahalul.stepsbridge`.
     iOS clients accept the app's custom-scheme redirect and don't issue a client
     secret — the app works without one.
   - Alternative: **Web application** (what Google's Health API guide shows). It issues a
     client secret, but the Cloud Console may reject the custom-scheme redirect URI
     `com.yanivbahalul.stepsbridge:/oauth2redirect` for Web clients. If it does, use iOS.
5. Copy the **Client ID** (and the **Client secret**, only if you made a Web client).
6. **Link your Google Health profile**: on your phone, install the "Google Health" app
   (App Store/Play Store) and sign in with the same Google account before first connecting
   from StepsBridge — the OAuth consent screen can't detect this for you.

## 2. Configure the app

Nothing to do: the app has this project's iOS OAuth client built in
(`Sources/Config/AppConfig.swift`), with the redirect URI
`com.googleusercontent.apps.84175655883-g6tnujthm7282dthp53sbljc4udstrqm:/oauth2redirect`
(the reversed client ID, which is the scheme Google expects for iOS clients). An iOS client
ID isn't a secret: it ships inside every app binary.

To use a different OAuth client, copy `Sources/Config/Secrets.example.plist` to
`Sources/Config/Secrets.plist` (gitignored), fill in your values, and set
`GOOGLE_OAUTH_REDIRECT_SCHEME` in `project.yml` to the redirect URI's scheme.

## 3. Generate the Xcode project and build

On a Mac, with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed
(`brew install xcodegen`):

```
cd fitness-google-sync   # the repo root, where project.yml lives
xcodegen generate
open StepsBridge.xcodeproj
```

In Xcode:
1. Select your Apple ID team under Signing & Capabilities (HealthKit requires a real
   device — it doesn't work in the Simulator).
2. Build and run on your iPhone.
3. Tap **Connect Google Health**, sign in, grant the steps permission.
4. Tap **Sync Now**. Open Apple Health → Browse → Activity → Steps to confirm the data
   landed there.

A GitHub Actions workflow (`.github/workflows/build.yml`) compiles the app on a macOS
runner on every push (unsigned, with placeholder config), so you know the code builds
before you open Xcode.

## What gets synced (last 14 days, every Sync Now)

| Google Health | Apple Health |
|---|---|
| steps, distance, active energy (summed per hour) | Steps, Walking + Running Distance, Active Energy |
| floors (per day) | Flights Climbed |
| heart rate (5-minute averages) | Heart Rate |
| daily resting heart rate | Resting Heart Rate |
| heart rate variability (SDNN, when provided) | Heart Rate Variability |
| oxygen saturation | Blood Oxygen |
| daily respiratory rate | Respiratory Rate |
| sleep sessions + stages | Sleep (In Bed, Core, Deep, REM, Awake) |
| exercise sessions | Workouts |
| weight, body fat, height | Weight, Body Fat %, Height |
| VO2 max | Cardio Fitness (VO2 max) |
| hydration log, nutrition log energy | Water, Dietary Energy |

Each sync deletes what StepsBridge itself wrote in the window and writes it fresh, so
nothing duplicates. Each type syncs independently; the app lists per-type counts and errors.

## How it works

- `Sources/Auth/GoogleAuthManager.swift` — OAuth 2.0 authorization-code + PKCE flow via
  `ASWebAuthenticationSession`, token refresh, refresh token stored in Keychain.
- `Sources/Health/GoogleHealthClient.swift` — `dataPoints` list / `:reconcile` /
  `:dailyRollUp` calls against `https://health.googleapis.com/v4/users/me/dataTypes/...`.
- `Sources/Sync/SyncCatalog.swift` — the Google Health → HealthKit mapping table.
- `Sources/Health/HealthKitWriter.swift` — replaces this app's samples per type.
- `Sources/Sync/SyncCoordinator.swift` — runs every catalog item on Sync Now.

## Known limitations

- Weekly re-authentication while the OAuth client is in Testing mode (see above).
- No background sync — iOS doesn't allow HealthKit writes from background without a
  much heavier setup (HealthKit background delivery is for *reading*, not writing from
  a third-party cloud source on a schedule). Manual "Sync Now" is the pragmatic choice
  given you already check in once a day.
- If Google changes the Google Health API response shape (it's a newly launched API as
  of 2026), `GoogleHealthClient.swift` may need updating — check
  <https://developers.google.com/health/endpoints> if sync starts failing.
