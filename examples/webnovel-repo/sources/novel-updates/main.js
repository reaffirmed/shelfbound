// Discovery source for translated web novels, in the style of Novel Updates.
//
// Novel Updates doesn't host chapters. It lists each release with a link that redirects
// to the translator's site, so getChapterContent returns { type: "link", url } and the app
// hands that URL to whichever installed source reads the site (see translator-sites),
// or offers reader mode.
//
// Selectors match the site as of this writing; check them with `shelf-repo run` when
// something comes back empty. The site may challenge automated clients, in which case
// requests fail with HTTP 403 and there is nothing a source can do about it.

const BASE = "https://www.novelupdates.com";

function abs(href) {
  if (!href) return null;
  if (href.startsWith("//")) return "https:" + href;
  if (href.startsWith("/")) return BASE + href;
  return href;
}

function first(html, selector) {
  return host.select(html, selector)[0] || null;
}

function texts(html, selector) {
  return host.select(html, selector).map((e) => e.text).filter(Boolean);
}

function slugFrom(url) {
  const m = /\/series\/([^/?#]+)/.exec(url || "");
  return m ? m[1] : null;
}

async function page(url) {
  const res = await host.fetch(url);
  if (res.status === 404) throw new Error("Novel Updates has no page for that series.");
  if (res.status === 403 || res.status === 503) throw new Error("Novel Updates turned the request away (HTTP " + res.status + "). Try again later.");
  if (res.status < 200 || res.status >= 300) throw new Error("HTTP " + res.status + " from Novel Updates");
  return res.body;
}

function chapterNumber(title) {
  const m = /(?:^|\b)(?:c|ch|chapter)\s*\.?\s*(\d+(?:\.\d+)?)/i.exec(title) || /(\d+(?:\.\d+)?)/.exec(title);
  return m ? Number(m[1]) : undefined;
}

globalThis.source = {
  async search(query, pageNumber) {
    const html = await page(`${BASE}/series-finder/?sf=1&sh=${encodeURIComponent(query)}&sort=srank&order=asc&pg=${pageNumber || 1}`);
    const results = host.select(html, ".search_main_box_nu").map((box) => {
      const link = first(box.html, ".search_title a");
      const img = first(box.html, ".search_img_nu img");
      const body = first(box.html, ".search_body_nu");
      const id = slugFrom(link && link.attrs.href);
      if (!id) return null;
      const blurb = body ? body.text.replace(/\.\.\.\s*more>>.*$/i, "…").replace(/<<less.*$/i, "").trim() : undefined;
      return {
        id,
        title: link.text,
        authors: [],
        coverURL: img && /^https:/.test(abs(img.attrs.src) || "") && !/noimagemid/.test(img.attrs.src) ? abs(img.attrs.src) : undefined,
        blurb,
        format: "novel",
        tags: texts(box.html, ".search_genre a").slice(0, 6),
      };
    }).filter(Boolean);
    return { results, hasMore: host.select(html, ".digg_pagination a.next_page").length > 0 };
  },

  async getWork(id) {
    const html = await page(`${BASE}/series/${encodeURIComponent(id)}/`);
    const title = first(html, ".seriestitlenu");
    if (!title) throw new Error("Couldn't read that series page.");
    const cover = first(html, ".seriesimg img");
    const description = first(html, "#editdescription");
    const status = first(html, "#editstatus");
    const lang = first(html, "#showlang");
    const translated = first(html, "#showtranslated");
    const type = first(html, "#showtype");
    const coverURL = cover ? abs(cover.attrs.src) : null;
    const statusText = status ? status.text : "";
    return {
      id,
      title: title.text,
      authors: texts(html, "#showauthors a"),
      coverURL: coverURL && coverURL.startsWith("https:") && !/noimage/.test(coverURL) ? coverURL : undefined,
      summaryHTML: description ? description.html : undefined,
      url: `${BASE}/series/${id}/`,
      format: "novel",
      fandoms: type ? [type.text.replace(/\s*\(.*\)\s*$/, "")] : undefined,
      tags: texts(html, "#seriesgenre a").concat(texts(html, "#showtags a")),
      status: /complete/i.test(statusText) ? "Completed" : statusText ? "Ongoing" : undefined,
      originalLanguage: lang ? lang.text : undefined,
      releaseGroup: translated && /yes/i.test(translated.text) ? "Fully translated" : undefined,
      language: "en",
    };
  },

  async getChapters(id) {
    const html = await page(`${BASE}/series/${encodeURIComponent(id)}/`);
    const postInput = first(html, "#mypostid");
    const postID = postInput && postInput.attrs.value;
    if (!postID) throw new Error("Couldn't find this series' chapter list.");
    const res = await host.fetch({
      url: `${BASE}/wp-admin/admin-ajax.php`,
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" },
      body: `action=nd_getchapters&mygrr=0&mypostid=${encodeURIComponent(postID)}`,
    });
    if (res.status < 200 || res.status >= 300) throw new Error("HTTP " + res.status + " loading chapters");
    const seen = new Set();
    const chapters = [];
    for (const item of host.select(res.body, "li.sp_li_chp")) {
      const link = first(item.html, "a[href*='/extnu/']");
      if (!link) continue;
      const m = /\/extnu\/(\d+)/.exec(link.attrs.href);
      if (!m || seen.has(m[1])) continue;
      seen.add(m[1]);
      const span = first(link.html, "span");
      const title = (span && span.attrs.title) || link.text || "Chapter";
      chapters.push({ id: m[1], title, number: chapterNumber(title), link: `${BASE}/extnu/${m[1]}/` });
    }
    // The site lists newest first.
    return chapters.reverse();
  },

  async getChapterContent(workID, chapterID) {
    // The release link redirects to the translator's page. Read the redirect instead of
    // following it, so the app can pick the source for that site.
    const res = await host.fetch({ url: `${BASE}/extnu/${encodeURIComponent(chapterID)}/`, redirect: "manual" });
    const location = res.headers.location || res.headers.Location;
    if (res.status >= 300 && res.status < 400 && location) {
      return { type: "link", url: abs(location) };
    }
    const refresh = /<meta[^>]+http-equiv=["']?refresh["']?[^>]+url=([^"'>\s]+)/i.exec(res.body || "");
    if (refresh) return { type: "link", url: abs(refresh[1]) };
    throw new Error("Novel Updates didn't say where this chapter is (HTTP " + res.status + ").");
  },
};
