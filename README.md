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
   - Under **Data access**, click "Add or remove scopes", search "Google Health API",
     and add: `.../auth/googlehealth.activity_and_fitness.readonly`.
4. Create the **OAuth client ID** (APIs & Services → Credentials → Create Credentials →
   OAuth client ID):
   - Google's Health API setup guide says to choose **Web application** as the type
     (it issues a client secret, needed for the refresh-token flow this app uses).
   - Authorized redirect URI: `com.yanivbahalul.stepsbridge:/oauth2redirect`
   - **Note:** if the Cloud Console rejects a non-`https` redirect URI for a Web
     application client, switch the client type to **iOS** or **Desktop app** instead —
     those accept custom URL schemes. This app's code doesn't change either way; only
     the console step does.
5. Copy the **Client ID** and **Client secret**.
6. **Link your Google Health profile**: on your phone, install the "Google Health" app
   (App Store/Play Store) and sign in with the same Google account before first connecting
   from StepsBridge — the OAuth consent screen can't detect this for you.

## 2. Configure the app

```
cp Sources/Config/Secrets.example.plist Sources/Config/Secrets.plist
```

Edit `Sources/Config/Secrets.plist` and fill in:
- `GoogleOAuthClientID` — the Client ID from step 1.5
- `GoogleOAuthClientSecret` — the Client secret from step 1.5
- `GoogleOAuthRedirectURI` — leave as `com.yanivbahalul.stepsbridge:/oauth2redirect`
  unless you changed the bundle ID in `project.yml`, in which case match it there too.

`Secrets.plist` is gitignored — it will never be committed.

## 3. Generate the Xcode project and build

On a Mac, with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed
(`brew install xcodegen`):

```
cd StepsBridge
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

## How it works

- `Sources/Auth/GoogleAuthManager.swift` — OAuth 2.0 authorization-code + PKCE flow via
  `ASWebAuthenticationSession`, token exchange/refresh against
  `https://oauth2.googleapis.com/token`, refresh token stored in Keychain.
- `Sources/Health/GoogleHealthClient.swift` — calls
  `POST https://health.googleapis.com/v4/users/me/dataTypes/steps/dataPoints:dailyRollUp`
  for the trailing 14 days.
- `Sources/Health/HealthKitWriter.swift` — writes one `HKQuantitySample` per day into
  Apple Health, tagged with metadata so re-syncing the same day overwrites instead of
  duplicating.
- `Sources/Sync/SyncCoordinator.swift` — orchestrates the two above on button tap.

## Known limitations

- Weekly re-authentication while the OAuth client is in Testing mode (see above).
- No background sync — iOS doesn't allow HealthKit writes from background without a
  much heavier setup (HealthKit background delivery is for *reading*, not writing from
  a third-party cloud source on a schedule). Manual "Sync Now" is the pragmatic choice
  given you already check in once a day.
- If Google changes the Google Health API response shape (it's a newly launched API as
  of 2026), `GoogleHealthClient.swift` may need updating — check
  <https://developers.google.com/health/endpoints> if sync starts failing.
