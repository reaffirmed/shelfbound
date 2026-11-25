# Getting Shelfbound onto the App Store

This folder has everything for the App Store version. The code side is done (see "What's in the app" below). The rest needs your Apple Developer account, so it's yours to do. Steps are in order; each says roughly how long it takes.

## What's in the app

- **Two flavors from one codebase.** The `Shelfbound App Store` scheme (configuration `AppStore`, Swift flag `APP_STORE`) is the store build. The plain `Shelfbound` scheme is the sideload build that GitHub Actions turns into the IPA, unchanged. Both ship with **no sources and no repos**; the store build also asks "Are you 18 or older?" before explicit sources show, and hides import of backups from sideloaded reader apps. See `App/Shelfbound/Model/AppFlavor.swift`.
- **Your own files first.** EPUB, PDF and CBZ import from the Library (empty state and the toolbar button), from Settings, and from "Open in Shelfbound" in Files and other apps. EPUB chapters follow the book's table of contents with images kept; picture-only EPUBs (most manga EPUBs) and CBZ open in the image readers; PDFs open as pages, split into chapters by their bookmarks.
- **Store requirements:** app icon, privacy manifests (`PrivacyInfo.xcprivacy`) for the app and widgets, the export-compliance flag, the Books category, and a Privacy policy link in Settings.
- **A workflow that signs and uploads without a Mac:** `.github/workflows/testflight.yml`.

## Your steps

### 1. Join the Apple Developer Program (a day or two)

developer.apple.com/programs › Enroll. $99 a year. Enroll as an individual unless you have a company; individual is faster and your name shows as the seller. Apple verifies your identity, which can take up to 48 hours.

### 2. Create the app in App Store Connect (10 minutes)

appstoreconnect.apple.com › Apps › + › New App.
- Platform iOS, name from `listing.md`, language, SKU anything (e.g. `shelfbound`).
- Bundle ID: `app.shelfbound.Shelfbound`. If it isn't in the list yet, run the workflow in step 4 once with **Upload** off; Xcode registers it, along with the widget's ID and the app group. If Apple says the ID is taken, tell me and I'll change the prefix.

### 3. Make an API key and add four secrets to GitHub (10 minutes)

1. App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › +. Name it "GitHub", access **Admin** (needed so the build can create the signing certificate). Download the `.p8` file; Apple lets you download it only once.
2. Note the **Key ID** next to it and the **Issuer ID** above the list.
3. Find your **Team ID** at developer.apple.com › Account › Membership details.
4. GitHub › this repo › Settings › Secrets and variables › Actions › New repository secret, four times:
   - `APPLE_TEAM_ID`
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
   - `ASC_KEY_P8`: open the `.p8` in a text editor and paste all of it, including the BEGIN and END lines.

### 4. Build and upload (about 20 minutes, mostly waiting)

GitHub › Actions › **App Store build** › Run workflow. When it's green, the build shows up in App Store Connect › TestFlight after Apple processes it (10 to 30 minutes). Every run gets a higher build number automatically. To ship a new version later, bump `MARKETING_VERSION` in `App/project.yml`.

### 5. Test it with TestFlight (as long as you like)

Install the TestFlight app on your iPhone, add yourself as an internal tester in App Store Connect › TestFlight, and install the build. Check importing a few of your own files.

### 6. Fill in the listing (an hour)

In App Store Connect, on the version page:
- Description, keywords, subtitle, promotional text: `listing.md`.
- Screenshots: see `listing.md`. Only your own files or public-domain books.
- Privacy policy URL: publish `privacy-policy.md` first (add your contact email to it), then use its URL. The GitHub link works once this branch is merged to main; a GitHub Pages page looks more polished.
- App Privacy: Data Not Collected.
- Age rating questionnaire: see `listing.md`.
- App Review Information: notes from `review-notes.md`, and your phone and email for the reviewer.

### 7. Submit for review (1 to 3 days)

Select the build, then Add for Review › Submit. If it's rejected, paste the message to me and we'll work out the reply or the fix.

## The honest risk

Review is likely to focus on sources. Apple allows apps to run downloaded JavaScript in JavaScriptCore (guideline 4.7), and many apps do; but reader apps whose main purpose is pulling manga or fanfic from sites that didn't authorize it are usually rejected or later removed under 5.2.2 and 5.2.3. That's why the store build leads with your own files, ships nothing, and lists nothing. It improves the odds; it doesn't guarantee approval.

If review insists, the fallback is a store build with sources turned off completely (a few lines behind `APP_STORE`), keeping them in the sideload build. That version would very likely pass, since it's then a straightforward file reader.

Never mention specific sites, other reader apps or series names in the listing, screenshots, review notes or support pages, and don't publish a "recommended repos" list from the same account. That link between the app and particular sites is what turns a tool into a target.

## Monetizing later

See `subscription-plan.md`. Short version: subscribe for app features (sync, read-aloud, themes, stats), never for access to anything sources fetch.
