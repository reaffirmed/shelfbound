# Web novel repo (example)

Two sources that work together for translated web novels:

- **Novel Updates** (`discovery`) finds novels and lists their releases. It doesn't host chapters: each release is a link to the translator's site, and the source reads where that link redirects without following it.
- **Translator sites** (`links`) reads chapter pages on WordPress and Blogger sites and strips the navigation, share buttons and ads. Add the hosts you read to its `domains`.

In the app, opening a chapter goes: Novel Updates gives the translator's URL, the app hands it to the source whose domains match, and the text shows in the normal text reader with your theme and glossary. If no source reads that site, the reader offers reader mode or opening it in the browser.

Both are rated `mature` because Novel Updates lists adult novels too.

```sh
npm test                                                        # offline, against fixtures/
npx ../../sdk/shelf-repo run sources/novel-updates search "cultivator" 1
npx ../../sdk/shelf-repo build
```

The selectors match the sites at the time of writing. Novel Updates may challenge automated clients; when it does, requests fail with HTTP 403 and the app shows that error. Check the site's terms before publishing a repo with these sources.
