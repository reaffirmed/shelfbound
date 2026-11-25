# AO3 repo (example)

An Archive of Our Own source, kept out of the app and out of the template repo on purpose. Publish it from your own repo if AO3's terms work for what you're doing.

- Rated `explicit`, so it only shows when Settings → Show sources rated up to is set to Explicit.
- `rateLimit.minIntervalMs` is 3000: one request every three seconds. AO3 answers bursts with 429, and the app backs off further when it does.
- Logged out only. Works restricted to registered users show a clear error instead of a login page.
- Filters: sort, complete or in progress, rating, language, archive warnings to leave out, and no crossovers.
- Adds `view_adult=true` so works with an adult-content interstitial load directly. The app's own rating setting is the gate.

```sh
npm test                                                   # offline, against fixtures/
npx ../../sdk/shelf-repo run sources/ao3 search "tea" 1 '{"sort":["kudos_count"]}'
npx ../../sdk/shelf-repo build
```

When AO3 changes its markup, save fresh pages into `test/fixtures/` and fix the selectors in `sources/ao3/main.js` until the tests pass.
