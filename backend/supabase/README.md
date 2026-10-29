# Accounts, friends, and shared tennis sessions

The hosted setup was completed on October 28, 2026:

- Supabase project: `birutnqxduzwldvymeun` (West US/Oregon).
- `001_social.sql` was applied successfully; all six app tables exist. **Do not run it again on this project.**
- Google OAuth client is configured in Google Cloud project `robust-cooler-513018-e0` and enabled in Supabase.
  Its secret is stored in Supabase, not in app resources or this repository.
- Google remains in **Testing** mode. The project owner's Google account is the sole test user.
  Add another consenting tester in Google Auth Platform → Audience before testing shared sessions on two accounts.
- Only basic identity scopes are configured: OpenID, email, and profile.
- `tennisbuddee://auth/callback` is in Supabase's allowed redirect URLs.
- The ignored local `apple/Shared/Resources/BackendConfig.plist` contains the project URL and publishable key;
  the configured Mac/iPhone builds pass. It contains no Google client secret or Supabase service key.
- The public auth endpoint confirms both Google and Apple are enabled. Anonymous reads of all six
  app tables return HTTP 401, as intended.
- The configured Mac app opens successfully to Racket → Account. Unsigned Mac development builds now
  check their iCloud entitlements before starting CloudKit and use local storage when those are absent.
- Native Apple sign-in is active for `com.quentinlynch.tennisbuddy` on Apple team `3KJ46YFZM9`.
  The existing Apple Developer App ID is enabled as a primary App ID, and the Supabase Apple provider
  accepts that bundle ID. No web Services ID, Apple private signing key, or OAuth secret is used.
- The signed iPhone/Watch development build succeeds. Both the iPhone code signature and the refreshed
  provisioning profile include `com.apple.developer.applesignin = [Default]`. All 17 app tests pass.
- Signed Mac development testing is blocked because this Mac is not registered with the Apple team.
  The unsigned Mac build passes but cannot validate native Apple authorization. Register the Mac and
  refresh its Mac App Development profile before testing Apple sign-in there.
- A real Apple/Google sign-in and two-player session still need testing on a signed device build.

Without local connection configuration the app works in guest mode.

## Setup reference for a new project

1. For a **new** Supabase project, run `001_social.sql` once in its SQL editor. The current project is already installed.
2. In Supabase Authentication, configure Google OAuth with its project callback URL. For **native Apple**
   sign-in, enable Sign in with Apple on the existing Apple Developer App ID and configure Supabase's
   Apple provider with Client IDs `com.quentinlynch.tennisbuddy`. Leave the OAuth secret empty.
   Services IDs, a `.p8` signing key, and six-month OAuth secret rotation are needed only if adding
   Apple's separate browser OAuth flow; the phone/Mac apps now use native ID-token sign-in.
3. Add `tennisbuddee://auth/callback` to Supabase's allowed redirect URLs. The iPhone/Mac apps already
   register the `tennisbuddee` URL scheme and use the SDK's ASWebAuthenticationSession/PKCE flow.
4. Copy `BackendConfig.plist.example` to `apple/Shared/Resources/BackendConfig.plist`. Fill in the project
   URL and **publishable** client key. Do not use a service-role or secret key. The local file is ignored by Git.
5. Regenerate the Xcode project with `xcodegen generate --spec apple/project.yml`, then build and run.
   Do this after adding the plist so it is copied into app resources. OAuth sessions use the SDK's default
   Apple Keychain storage. The Watch does not hold a Supabase token.
6. Sign in on two test devices. Set names in Racket → Account. In Together, share a friend code once,
   send the request, and accept it from the other account. Each player can then invite the other directly.
   The invited player opens Together and accepts; no session code is needed between friends.

Official setup references: [Google](https://supabase.com/docs/guides/auth/social-sign-in/auth-google),
[Apple](https://supabase.com/docs/guides/auth/social-sign-in/auth-apple),
[Swift OAuth](https://supabase.com/docs/reference/swift/auth-signinwithoauth), and
[database function security](https://supabase.com/docs/guides/database/functions).

## Behaviour and boundaries

- Friend requests require acceptance. Pending requests expose names, not the other player's friend code.
  Friends can be removed. Removing a friend cancels pending invitations between those two players.
- Each direct invitation creates a shared match. Alternatively, share a random 12-character session code.
  Invitations/codes expire for new participants after 24 hours. Only two participants can join.
- Both players can log points and undo the latest point. The ordered log drives standard best-of-three,
  advantage scoring with normal set tiebreaks. A row lock and monotonic revision reject conflicting writes;
  operation UUIDs make retries idempotent. Undo retains a tombstone so a late retry cannot restore it.
- Together refreshes every two seconds **while the page is foreground**. Invitations are in-app;
  push notifications and background realtime subscriptions are not part of this implementation.
  Keep Together open on the iPhone for live shared Watch score updates. A reachable paired iPhone is
  required to send shared points from the Watch. Shared points are acknowledged before another is sent.
- Match scoring requires no racket. Either player can connect their own racket, then choose Record my
  racket stats. Each player's real racket summaries are uploaded every five seconds in the foreground.
  Simulator/replay data is excluded; microphone-only shots have no invented speed values. Multiple local
  recordings for the same match are aggregated. Pending summary uploads persist for later retries.
- Shared stats include shot count, sweet-spot percentage, average/top ball speed. Heart rate, calories,
  notes, raw recordings, and private session history are excluded. Each user can write only their own summary.
- Profiles/friendships/matches live in Supabase. Private sessions and skins remain in the existing local/iCloud
  storage and are not a Supabase account backup. Account switching does not partition private iCloud history.
- Table access is denied to both anonymous and authenticated roles. Narrow authenticated SQL functions
  validate membership and ownership before accessing data. Service-role access is never used by the app.

## Validation

Run `npm ci --prefix backend/supabase` then `npm test --prefix backend/supabase`.
The test runs the actual migration in embedded PostgreSQL (PGlite), with Supabase auth claims modelled
locally. It checks friend consent, invitations, participant isolation, direct-table denial, point retries,
stale revisions, undo, participant stats ownership, ended matches, and joining by code.

Before release, complete a real two-account OAuth/device test against the configured project, verify provider
branding and callback behaviour, add the required privacy/support/account-deletion flows, and decide whether
in-app invitations need push delivery. Deployment configuration, real provider login, live two-device networking,
Health/Activity ring credit, and hardware firmware transfers cannot be validated by these local tests.

## Native Apple sign-in

The app uses Apple's standard Sign in with Apple button and system sheet on iPhone and Mac.
Each request gets independent random 256-bit nonce/state values. Apple receives SHA-256(nonce),
the returned state is validated, and Supabase receives the signed Apple ID token plus the original nonce.
Challenges are consumed on completion, including cancellation. No Apple developer private key is bundled.
Apple's first-sign-in name is saved in account metadata and used for the player profile only if its name
is still the default. Later sign-ins do not erase an existing custom name.

The Xcode project includes `com.apple.developer.applesignin = [Default]` on iOS and Mac. Use a properly
signed build with updated provisioning profiles for a real sign-in. The unsigned Mac development build
can show the screen but cannot be used to validate native Apple authorization. The Watch uses its paired
phone's account rather than holding its own Supabase credentials.

See [Supabase's Apple guidance](https://supabase.com/docs/guides/auth/social-sign-in/auth-apple) and
[Swift ID-token authentication](https://supabase.com/docs/reference/swift/auth-signinwithidtoken).
