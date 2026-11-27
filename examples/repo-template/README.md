# Example Shelfbound repo

A repo is a folder of sources plus a signed `index.json` that you host anywhere static, such as GitHub Pages.

```
repo.json                 name and maintainer
sources/<name>/manifest.json
sources/<name>/main.js
sources/<name>/icon.png   optional
```

## Make your own

```sh
npx shelf-repo keygen              # once; keep signing.key secret and out of git
npx shelf-repo run sources/gutenberg search "pride" 1
npx shelf-repo build               # writes dist/index.json and dist/packages/
```

Publish `dist/` and give people the URL of the folder. The app pins your public key the first time someone adds the repo, so keep `signing.key` safe: if you lose it, everyone has to remove and re-add your repo.

## Writing a source

`manifest.json`:

| Field | Meaning |
| --- | --- |
| `id`, `name`, `version` | Reverse-DNS id, display name, and a version like `1.2.0` |
| `kind` | `text` or `images` |
| `format` | Optional. `fic` or `novel` for text; `manga` (right to left), `manhwa`, `manhua` (vertical) or `comic` (left to right) for images. Picks the default reader |
| `contentRating` | `safe`, `mature` or `explicit`. People choose the highest rating they see in Settings |
| `languages`, `domains` | Languages, and every host the source contacts. `*.example.org` allows subdomains |
| `rateLimit` | Optional. `{ "minIntervalMs": 3000 }` spaces requests further apart than the default one second |
| `capabilities` | Optional. `filters` (has `getFilters`), `links` (has `resolveLink`), `listings` (has `getListings` and `getListing`), `account` (sign-in, see below), `discovery` (chapters live on other sites) |
| `account` | With the `account` capability: `{ "loginURL": "https://example.org/login" }`, the site's own sign-in page on one of `domains` |

`main.js` sets `globalThis.source` to an object with these async functions:

| Function | Returns |
| --- | --- |
| `search(query, page, filters)` | `{ results: [{ id, title, authors, coverURL?, blurb?, format?, fandoms?, rating?, tags?, wordCount?, chapterCount?, kudos?, updatedAt? }], hasMore }` |
| `getWork(id)` | `{ id, title, authors, coverURL?, summaryHTML?, url?, format?, rating?, warnings?, categories?, fandoms?, relationships?, characters?, tags?, language?, wordCount?, chapterCount?, status?, kudos?, bookmarks?, hits?, publishedAt?, updatedAt?, series?: [{ title, part?, id?, url? }], originalLanguage?, translators?, releaseGroup?, downloads? }` |
| `getChapters(id)` | `[{ id, title, number?, publishedAt?, group?, link? }]`, oldest first. `group` is the scanlation or translation group; `link` is where the chapter lives if it's on another site |
| `getChapterContent(id, chapterId)` | `{ type: "text", html, notesBefore?, notesAfter? }`, `{ type: "images", pages: [url or { url, headers }] }`, or `{ type: "link", url }` |
| `getFilters()` | Optional. `[{ id, label, type, options?: [{ id, label }], default?: [id], placeholder?, excludable?, suggests?, group?, workField? }]`. See "Search filters" below |
| `suggest(filterID, text)` | Optional. Names for a `tags` filter with `suggests: true` that match what the person typed: `[{ id, label }]` |
| `getListings()` | Optional, with the `listings` capability. `[{ id, title, subtitle? }]`: lists people can browse without searching, like "Freshly updated", "Trending" or "Best of all time". The first one shows on the Browse tab |
| `getListing(id, page)` | Optional, with the `listings` capability. One page of a list from `getListings`, shaped like `search`'s result: `{ results, hasMore }` |
| `getSeries(id, page)` | Optional (app 0.6 and later). One page of the works in a series, in the series' order, shaped like `search`'s result. `id` is the `id` of an entry in `getWork`'s `series`. With it, a series on a work's page opens in the app; without it, the series links to `url` |
| `idFromURL(url)` | Optional. The work ID for a link to a work on your site, or `null`. Lets people import a list of links (AO3 bookmarks, a reading list) |
| `resolveLink(url)` | Optional, with the `links` capability. Reads a chapter page on one of your `domains` that another source handed over, and returns chapter content |

With the `account` capability, the person signs in on `account.loginURL` in a web view. The app keeps the site's cookies in the Keychain (never a password), sends them with every `host.fetch` to the site, and passes the username as `host.settings.get("account")` (null when signed out). The source adds:

| Function | Returns |
| --- | --- |
| `getAccount()` | `{ username, url? }` for whoever the site shows as signed in, or `null`. Called after sign-in and from "Check sign-in" |
| `getAccountLists()` | `[{ id, title, subtitle?, importable? }]`: the person's own lists, like bookmarks or a reading list. `importable` lists get **Import** and **Keep in sync** in Settings › Accounts |
| `getAccountList(id, page)` | One page of a list, shaped like `search`'s result |
| `setWorkState(id, key, value)` | Optional. `key` is `markedForLater`, `subscribed` or `kudos`. Does it on the site and returns the work's state after, like `getWork`'s `account` |

`getWork` may then return `account: { markedForLater?, subscribed?, kudos? }`, which shows as buttons on the work's page. `setWorkState` only runs when the person taps one of those buttons; syncing lists only ever adds to the library.

Dates are ISO 8601 strings, like `new Date().toISOString()` or `"2024-05-01"`.

When `getChapterContent` returns a link, the app gives it to an installed source with the `links` capability whose domains match. If none does, the reader offers reader mode, which pulls the text out of the page, or opening it in the browser.

The only API available is `host`:

- `host.fetch(urlOrRequest)` returns `{ status, url, headers, body }`. A request is `{ url, method?, headers?, body?, redirect? }`. Only hosts in `manifest.domains` are reachable, including redirect targets. With `redirect: "manual"` the redirect response itself comes back, so you can read `headers.location`.
- `host.fetchJSON(urlOrRequest)` fetches and parses JSON.
- `host.select(html, cssSelector)` returns `[{ text, html, outerHTML, attrs }]`.
- `host.needsBrowserVerification(url)` stops the call and asks the person to open `url` in the app's browser to pass a check the app can't detect by itself. Cloudflare challenges are detected for you: `host.fetch` throws on them and the app takes over.
- `host.settings.get(key)` and `host.log(...)`. `host.settings.get("maxRating")` is the highest rating the person chose to see.

There are no timers, files, `URL` class, or other network APIs. Use `encodeURIComponent` to build query strings.

## Sites with bot checks

When a site answers with a Cloudflare challenge (or a source calls `host.needsBrowserVerification`), the app shows **Verify in browser**. The person completes the check themselves in a web view. The app then keeps that site's cookies and sends the same browser User-Agent on requests to the site, until the clearance expires and the app asks again. Background downloads from that site pause, and the person gets a notification, rather than the downloads failing.

Sources don't need to do anything for this. Don't add challenge solvers, CAPTCHA services or proxy rotation: repos that do can be blocked.

## Testing a source

`shelf-repo run` calls a source against the live site. For tests that don't break when you're offline, save pages into a `fixtures` folder and use `loadSource` from `sdk/shelf-repo/lib/runner.mjs` with a fake `fetchImpl`. The AO3 and web novel example repos do this.

## Be a good guest

Only add sources for sites whose terms allow it, and respect their rate limits, login and adult-content gates. Repos that point at pirated content can be blocked from the app.

## Search filters

`search(query, page, filters)` gets `filters` as `{ [id]: [String] }`. The query can be
empty when the person searches by filters alone.

| `type` | What the person sees | Value |
|---|---|---|
| `select` | A menu with one choice | `[optionID]` |
| `multi` | A menu with several choices | `[optionID, ...]` |
| `toggle` | An on/off chip | `["true"]` or `[]` |
| `text` | A text field | `[text]` |
| `range` | Min and max number fields. `placeholder` is the unit, like "words" | `[min, max]`, either may be `""` |
| `tags` | Names to include, and with `excludable: true` names to leave out, which arrive under `"<id>.exclude"`. Suggestions come from `options`, or from `suggest()` when `suggests: true` | `[name, ...]` |

`group` puts filters under a heading on the Filters screen. `workField` names the work
field the filter searches by (`fandoms`, `relationships`, `characters`, `tags`,
`warnings`, `categories`, `rating`, `language` or `authors`): tapping one of those tags
on a work's page then opens a search for it, and holding it offers a search without it.
An `authors` filter is what an author's page uses to list their works (app 0.6 and later);
without one, the app searches for the author's name.

Apps before 0.4 only know `select`, `multi` and `toggle`. Check `host.filterTypes`
before offering the others:

```js
const newKinds = (host.filterTypes || []).includes("tags");
```
