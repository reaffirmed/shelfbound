# Subscription plan

Goal: a monthly subscription that App Review will accept and that doesn't expose you legally. Not built yet; this is the plan for when the free version is live.

## The rule that decides everything

Charge only for what **Shelfbound itself** does. Never for access to anything a source fetches.

If the paywall unlocks reading, searching or downloading from third-party sites, you are selling other people's content. That is a copyright problem in most countries (it turns "a reader tool" into "a business profiting from unlicensed works"), and it breaks App Store guideline 5.2.2 and 5.2.3. Reviewers look at what the subscription unlocks first. Keep the reader, importing, and sources fully free, and the subscription is easy to defend.

## What could be in "Shelfbound Plus"

Features that are clearly the app's own work, roughly in order of value versus effort:

| Feature | Why it's a fair thing to charge for | Effort |
| --- | --- | --- |
| iCloud sync of library, places, highlights across iPhone, iPad and Mac | Ongoing service, the classic subscription justification | Medium (CloudKit, conflict handling) |
| Extra reader themes and fonts, custom theme editor | Pure app feature | Small |
| Read aloud (text-to-speech) with voice choice, sleep timer, lock screen controls | Clearly app work, works on imported books too | Medium |
| Reading stats and goals (time read, streaks, yearly recap) | App-owned data | Small to medium |
| Smart collections and tags beyond series grouping | App feature | Small |
| Faster background update checks and richer notifications | Defensible, but the "update checks" touch third-party sites; keep it about frequency, not access | Small |

Guideline 3.1.2(a) requires a subscription to give ongoing value, so sync or read-aloud should anchor it. Themes alone won't pass as a subscription; they could be a one-time unlock instead.

## Pricing shape

- Monthly plus yearly (yearly at roughly 8 to 10 months' price). A one-week or one-month free trial converts best for readers.
- Optionally a lifetime unlock. Many reader-app users prefer it, and it doesn't need "ongoing value".
- Everything currently in the app stays free, forever. Taking free features away later causes one-star reviews and can draw a guideline 3.1.2 complaint.

## How to build it (when you're ready)

1. In App Store Connect: Agreements, Tax, and Banking (the Paid Apps agreement), then a subscription group "Shelfbound Plus" with monthly and yearly products.
2. In the app: StoreKit 2 (`Product.products(for:)`, `Transaction.currentEntitlements`, `Transaction.updates`). No server needed for an app this size; StoreKit 2 verifies transactions on the device.
3. A paywall sheet that names exactly what Plus includes, the price, the renewal terms, and links to the Terms of Use (Apple's standard EULA is fine) and the privacy policy. Restore Purchases button. All of this is checked in review (3.1.2).
4. A StoreKit configuration file in Xcode for local testing, then TestFlight sandbox testing.
5. Gate only the Plus features behind `isPlus`. Only the App Store build should show the paywall; the sideload build can keep everything unlocked or hide Plus.

## Risks to know before charging

- **Legal exposure grows once you earn money.** A free open tool that people point at sites themselves is one thing; a paid product whose marketing or screenshots suggest "read manga free" is how scraper apps get takedown notices. Keep the listing about your own files.
- **Removal risk is higher for paid apps.** If a rights holder complains to Apple about what sources can reach, Apple can pull the app. Subscribers then lose what they paid for, and refunds come out of your proceeds. That's another reason to make Plus about features that keep working on imported files.
- **Apple takes 15%** under the Small Business Program (apply in App Store Connect; under $1M a year), 30% otherwise. For subscriptions it drops to 15% after a subscriber's first year in either case.
- **Taxes:** proceeds count as income. In most places you'll want to register as a sole proprietor or small business once it's meaningful. Not legal advice; worth one conversation with an accountant before launch.
