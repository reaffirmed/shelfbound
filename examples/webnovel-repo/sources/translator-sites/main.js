// Link source: reads chapter pages on translators' own sites, for chapters that a
// discovery source (like Novel Updates) hands over as links.
//
// It handles the common WordPress and Blogger layouts. Add the hosts you read to
// manifest.json "domains"; the app only sends this source links on those hosts, and
// anything else falls back to the app's reader mode.

const CONTAINERS = [".entry-content", ".post-body", ".chapter-content", "#chapter-content", "article .content", "article"];

// Paragraphs that are navigation or housekeeping rather than story: nothing left once
// nav words and separators are taken out.
const NAV_WORDS = /\b(?:previous|prev|next|chapter|table of contents|contents|toc|index|home|back|main page)\b|[|｜/\\«»<>←→:\-–—\s]+/gi;
const HOUSEKEEPING = /^(?:share this|like this|related|advertisement|loading\.*|support (?:me|us)\b.*|buy me a coffee.*|ko-?fi.*|patreon.*)$/i;

function isJunk(text) {
  return text.replace(NAV_WORDS, "").trim() === "" || HOUSEKEEPING.test(text);
}

function stripText(html) {
  return html.replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();
}

function blocks(html) {
  // Top-level blocks in order. Simple on purpose: WordPress posts are mostly flat <p>s.
  return html.match(/<(p|h[1-6]|blockquote|hr|ul|ol)(?:\s[^>]*)?>[\s\S]*?<\/\1>|<hr\s*\/?>/gi) || [];
}

function clean(block) {
  return block
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/\s(?:style|class|id|data-[\w-]+)="[^"]*"/gi, "");
}

function extract(html) {
  for (const selector of CONTAINERS) {
    const found = host.select(html, selector)[0];
    if (!found) continue;
    const body = found.html
      .replace(/<div[^>]+class="[^"]*(?:sharedaddy|jp-relatedposts|wpcnt|code-block|wp-block-buttons|post-navigation)[^"]*"[\s\S]*?<\/div>/gi, "");
    const kept = blocks(body).filter((b) => {
      const text = stripText(b);
      return /^<hr/i.test(b) || (text.length > 0 && !isJunk(text));
    });
    const words = kept.map(stripText).join(" ").split(/\s+/).filter(Boolean).length;
    if (words >= 80) return kept.map(clean).join("\n");
  }
  return null;
}

globalThis.source = {
  // Not a catalogue: this source only reads links. Search returns nothing.
  async search() {
    return { results: [], hasMore: false };
  },
  async getWork(id) {
    throw new Error("This source only reads chapter links.");
  },
  async getChapters() {
    return [];
  },
  async getChapterContent() {
    throw new Error("This source only reads chapter links.");
  },

  async resolveLink(url) {
    const res = await host.fetch(url);
    if (res.status === 404) throw new Error("The translator's page is gone (404).");
    if (res.status < 200 || res.status >= 300) throw new Error("HTTP " + res.status + " from " + url);
    const html = extract(res.body);
    if (!html) throw new Error("Couldn't find the chapter text on that page.");
    return { type: "text", html };
  },
};
