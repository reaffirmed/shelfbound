# Notes for App Review

Paste the text below into App Store Connect › your app › the version › **App Review Information › Notes**. Attach a short screen recording of the import flow as well (Apple accepts a link or file there).

---

Shelfbound is a reader for the person's own books and comics. On first launch the library is empty. Tap **Import files** (or Settings › Import books and comics) to add EPUB, PDF or CBZ files from Files or iCloud Drive. Files shared to Shelfbound from other apps are imported the same way.

To test without your own files, these public-domain books work: any EPUB from Project Gutenberg (gutenberg.org), and any PDF.

Shelfbound also supports optional extensions ("sources") that the user adds themselves from a repository URL they type in, under Discover › Add repository. The app ships with no sources, no built-in repositories, and no list or directory of repositories. Sources are small JavaScript files that run in a sandboxed JavaScriptCore context (guideline 4.7). They have no access to native APIs, the file system or other sources; their only capability is fetching pages from the domains their manifest declares, rate-limited, and they return plain data that the app validates before display. Each repository is signed, and the app pins its key on first add.

Content shown through a source comes from the website the user chose to connect to, not from us. Sources rated explicit stay hidden unless the user confirms they are 18 or older in Settings.

The app has no account system of its own and collects no data. Privacy policy: https://github.com/reaffirmed/shelfbound/blob/main/docs/app-store/privacy-policy.md

---

## Before you submit, check

- The screenshots show only your own imported files or public-domain books. Nothing from a third-party site.
- The description and keywords name no websites, other reader apps, or copyrighted series.
- The demo instructions above match the build you upload.
