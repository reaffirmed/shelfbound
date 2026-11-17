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

`main.js` sets `globalThis.source` to an object with four async functions:

| Function | Returns |
| --- | --- |
| `search(query, page)` | `{ results: [{ id, title, authors, coverURL?, blurb? }], hasMore }` |
| `getWork(id)` | `{ id, title, authors, summaryHTML?, rating?, warnings?, fandoms?, relationships?, tags?, wordCount?, status?, downloads? }` |
| `getChapters(id)` | `[{ id, title, number?, publishedAt? }]` |
| `getChapterContent(id, chapterId)` | `{ type: "text", html, notesBefore?, notesAfter? }` or `{ type: "images", pages: [url] }` |

The only API available is `host`:

- `host.fetch(urlOrRequest)` returns `{ status, url, headers, body }`. Only hosts listed in `manifest.domains` are reachable, and the app spaces requests about one second apart per source.
- `host.fetchJSON(urlOrRequest)` fetches and parses JSON.
- `host.select(html, cssSelector)` returns `[{ text, html, outerHTML, attrs }]`.
- `host.settings.get(key)` and `host.log(...)`.

There are no timers, files, or other network APIs.

## Be a good guest

Only add sources for sites whose terms allow it, and respect their rate limits, login and adult-content gates. Repos that point at pirated content can be blocked from the app.
