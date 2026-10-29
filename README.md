# geo#

AR graffiti for iPhone. Your phone is the spray can: lock onto a real wall, walk in, hold, paint. The paint stays on that wall for everyone in the crew. Invite only.

```
ios/                      the app (SwiftUI + ARKit + Google ARCore Geospatial), built by GitHub Actions
  project.yml             Xcode project definition (XcodeGen generates the .xcodeproj on the build machine)
  GeoTag/                 source: App, AR, Paint, UI, Backend, Theme
  ci/                     secrets writer and TestFlight export settings
backend/schema.sql        the whole database: walls, pieces, crews, comments, props, reports, blocks
backend/admin.sql         founder codes, App Review code, moderation queue, bans
backend/functions/        optional ARCore token signer (makes wall fingerprints last a year)
docs/                     public site: home, terms, privacy, support (App Store needs these URLs)
.github/workflows/ios.yml compiles every push; "Run workflow" uploads to TestFlight
```

You don't need a Mac. GitHub's Mac servers build the app and send it to TestFlight; your iPhone installs it from there.

## What it does

- **Spray mode.** Aim the crosshair at a big flat wall 1 to 6 m away and tap *lock on* (you feel a thud). Walk in. Hold anywhere on the screen to spray. Distance sets the spray width, angle stretches it into an oval, lingering builds up paint until it drips, and pressure drains until you shake the phone (you'll hear the ball rattle). The ring on the wall shows exactly where paint will land. Undo takes back the last burst. *Post* puts it on the wall for everyone.
- **Sketch mode.** Lock on, and geo# freezes the camera and unwarps a 2.4 × 1.8 m patch of wall into a flat canvas. Draw with your finger (marker or spray, four sizes), then post. Better for lettering.
- **Look mode.** Every wall around you shows its art. Tap a piece to see who painted it, give props, comment, report, or block.
- **Layering.** New paint goes on top. A wall keeps every layer; the wall page lists them newest first.
- **Map.** Every painted wall within 5 km, with the latest artist and a "walk there" button. You can view any wall's art flat from anywhere.
- **Activity.** Props, comments, people going over your pieces, and who joined with your codes.
- **Crews.** Each new member gets 3 codes to share. The database remembers who invited whom, so a ban can take out a whole branch.
- **Practice mode.** Works anywhere, even indoors, with no account. Nothing is saved.

### How walls stay put

| Layer | What it fixes | Accuracy |
|---|---|---|
| Google Geospatial (Street View matching) | which wall | about a metre |
| ARKit plane snap | depth and angle, so art sits flush | centimetres |
| Cloud Anchor fingerprints (optional, see step 6) | sliding along the wall | centimetres |

A wall is only painted if it's vertical, at least 1.2 × 0.9 m, flat (checked with LiDAR on Pro iPhones) and, where the phone supports it, actually labelled as a building, so cars and trees are rejected. Phones report how well each stored wall matches what they see; if three different people see a mismatch, the wall is marked *changed* and its art is archived, not moved.

## One-time setup (about an hour, plus Apple's approval wait)

### 1. Apple Developer Program
Enroll at developer.apple.com/programs as an individual ($99 USD a year). Approval can take up to 48 hours. Then find your **Team ID** under Membership details.

### 2. Register the app
- developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App. Bundle ID: `com.kafkaesq.geotag` (explicit). No extra capabilities needed.
- appstoreconnect.apple.com → Apps → **+** → New App. Platform iOS, bundle ID as above, SKU `geotag`. The name has to be unique on the store; if "geo#" is taken try "geo# AR graffiti".

### 3. App Store Connect API key (lets GitHub upload builds)
App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → **+**. Name it "github", role **Admin** (needed so the build machine can create signing certificates). Download the `.p8` file (you only get one chance) and note the **Key ID** and **Issuer ID**.

### 4. Backend (Supabase)
- supabase.com → new project (free tier is fine).
- Authentication → Sign In / Providers → turn on **Allow anonymous sign-ins**.
- SQL editor → paste `backend/schema.sql` → Run.
- SQL editor → run steps **1** and **1b** from `backend/admin.sql` (your founder codes, and `APPREVIEW` for Apple). Add words to `banned_words` (step 3).
- Project Settings → API: copy the **Project URL** and the **anon public** key.

### 5. Google ARCore key
console.cloud.google.com → new project → APIs & Services → Library → enable **ARCore API** → Credentials → Create credentials → API key. Restrict it: API restrictions → ARCore API; Application restrictions → iOS apps → `com.kafkaesq.geotag`.

### 6. Optional: year-long wall fingerprints
With only an API key, Google limits Cloud Anchors to 24 hours, so geo# skips them and relies on Geospatial plus plane snap. For centimetre-level locking that lasts:
- Google Cloud → IAM → Service Accounts → create one → Keys → Add key → JSON. Keep that file private.
- Deploy the token signer with the Supabase CLI (works fine from a container on Kinoite):
  `supabase functions deploy arcore-token --project-ref YOUR_REF` then
  `supabase secrets set GOOGLE_SA_JSON="$(cat service-account.json)" --project-ref YOUR_REF`
- Add the GitHub secret `ARCORE_TOKEN_AUTH` = `true`.

### 7. Public pages
The App Store needs a privacy policy and support URL. Edit `docs/support.html` and replace `SUPPORT_EMAIL_HERE` with the address you want public. Then host the `docs` folder:
- **Easiest:** drag the `docs` folder onto app.netlify.com/drop. You get a URL like `https://geotag-xyz.netlify.app`.
- Or GitHub Pages (Settings → Pages → main / docs). Pages on a private repo needs a paid GitHub plan.

### 8. GitHub secrets
Repo → Settings → Secrets and variables → Actions → New repository secret, one each:

| Secret | Value |
|---|---|
| `SUPABASE_URL` | Project URL from step 4 |
| `SUPABASE_ANON_KEY` | anon public key from step 4 |
| `ARCORE_API_KEY` | key from step 5 |
| `SITE_URL` | your pages URL from step 7, no trailing slash |
| `SUPPORT_EMAIL` | the support address |
| `APPLE_TEAM_ID` | from step 1 |
| `ASC_KEY_ID` | from step 3 |
| `ASC_ISSUER_ID` | from step 3 |
| `ASC_KEY_P8` | open the .p8 in a text editor and paste the whole thing, BEGIN and END lines included |
| `ARCORE_TOKEN_AUTH` | `true` only if you did step 6 |

## Get it on your iPhone (TestFlight)

1. GitHub → **Actions** → **iOS** → **Run workflow** (leave "Upload this build to TestFlight" ticked). It takes 15 to 25 minutes. A green tick means Apple has the build.
2. App Store Connect → your app → **TestFlight**. The build shows "Processing" for 5 to 30 minutes.
3. TestFlight → Internal Testing → **+** → make a group called "crew", add yourself. Your own Apple ID is already a user.
4. On the iPhone, install the **TestFlight** app from the App Store, open the email invite (or TestFlight shows it directly), and install geo#.
5. First launch: read the notice, accept the rules, pick a name, enter a founder code.

To bring friends in: add them under Users and Access as internal testers (up to 100, no review), or create an External Testing group, submit the build for Beta App Review (about a day), and share the public TestFlight link. Then hand them crew codes from the "you" screen.

### First test, outside

- [ ] Stand across the street from buildings with Street View coverage. The status pill turns yellow, then green ("locked ±1.2 m").
- [ ] Spray: aim at a big flat wall 2 to 4 m away. "Lock on" turns pink. Tap it, feel the thud.
- [ ] Walk in to about 30 cm. Hold. Hiss, buzz, paint. Sweep fast for thin lines, linger for drips.
- [ ] Shake when the gauge goes yellow. Rattle, pressure back.
- [ ] Post. Switch to look mode, walk 50 m away and back. The piece is on the same bricks.
- [ ] Second phone: same wall, art within a hand-width. Go over it. Both show the new layer on top.
- [ ] Map shows the wall. Activity on the first phone says you went over it.
- [ ] Report, block, delete piece, delete comment all work.
- [ ] Sketch mode: the flattened backdrop lines up with the real wall.

## Submitting to the App Store

When TestFlight looks good:

1. **App information:** category Social Networking (secondary: Photo & Video). Privacy policy URL = `SITE_URL/privacy.html`.
2. **Pricing:** free.
3. **App privacy** (the "nutrition label"): Data linked to the user, used for App Functionality, not for tracking:
   Location → Precise Location; User Content → Other User Content (the art and comments); Identifiers → User ID.
4. **Age rating:** answer the questionnaire honestly. User-generated content with moderation usually lands at 13+ or 16+ under the current system.
5. **Version page:** screenshots from the iPhone (6.9" size, 1320 × 2868; take them on a Pro Max or use the 6.5" set), description, keywords (graffiti, street art, AR, spray, wall, crew), support URL = `SITE_URL/support.html`, the build from TestFlight.
6. **App Review notes** (this part matters for an AR app that needs a location):
   > geo# is invite only. Use crew code **APPREVIEW** with any name.
   > Seeing and posting art needs the device outdoors facing buildings that have Google Street View coverage (any city street works; it does not need to be Winnipeg).
   > To test painting anywhere, including indoors: on the first screen tap "no code? try practice mode", choose spray, aim at any wall 1 to 6 m away, tap "lock on", walk closer, then hold anywhere on the screen.
   > Moderation: every piece, comment and user can be reported or blocked from its "..." menu; reported content is hidden after 3 reports and reviewed within 24 hours. Users accept the terms (zero tolerance for objectionable content) before joining. Account deletion is under "you" → "delete my account".

   Attach a 1 to 2 minute screen recording of you painting a wall outside. Reviewers often ask for one for location-dependent apps.
7. **Add for Review → Submit.** Typical turnaround is 1 to 2 days. If they reject, the message says which guideline; most fixes are a reply or a small change.

Before the public release, also run `backend/admin.sql` step 4 daily (the moderation queue). Apple expects reports handled within 24 hours.

## Costs

- Apple Developer Program: $99 USD a year.
- Supabase: free tier covers a beta easily.
- Google ARCore API: free usage quota; check the quota page in Google Cloud if you grow.
- GitHub Actions: Mac build minutes count 10× against the free 2,000 minutes a month on a private repo, so roughly 10 builds a month free. Making the repo public makes them unlimited.

## Known limits

- **Not yet run on a phone.** It compiles on Apple's toolchain in CI, and the database was tested end to end, but nobody has painted with it yet. Expect tuning: spray width, drip threshold and lock-on distances are constants at the top of `SprayEngine.swift`.
- **The physical volume button can't be the trigger.** App Store rule 2.5.9 forbids repurposing the volume buttons, and Apple's camera-button API only works with a regular camera session, not ARKit. The whole screen is the trigger instead.
- **Coverage.** Geospatial needs Street View nearby; back alleys localise worse, indoors not at all (practice mode still works).
- **Flat walls only.** Rolling doors, pillars and deep brick reveals are rejected or float.
- **No occlusion yet.** A truck parked in front of a wall won't hide the art behind it.
- **Night.** Tracking gets worse in low light. LiDAR iPhones handle it better.
- **iPhone only for now.** Android needs its own app (Kotlin + ARCore) on the same backend.
