// Example text source: public-domain books from Project Gutenberg via the Gutendex API.
// It shows the four functions every source implements. Each book is split into
// chapters at its <h2> headings.

const API = "https://gutendex.com/books";

function htmlURL(book) {
  const formats = book.formats || {};
  const key = Object.keys(formats).find((k) => k.startsWith("text/html"));
  return key ? formats[key] : null;
}

function splitChapters(html) {
  const body = (html.match(/<body[^>]*>([\s\S]*)<\/body>/i) || [null, html])[1];
  const parts = body.split(/(?=<h2[\s>])/i);
  return parts
    .map((part, i) => {
      const heading = (part.match(/<h2[^>]*>([\s\S]*?)<\/h2>/i) || [null, ""])[1];
      const title = heading.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim() || (i === 0 ? "Front matter" : `Part ${i}`);
      return { title, html: part.replace(/<h2[^>]*>[\s\S]*?<\/h2>/i, "") };
    })
    .filter((c) => c.html.replace(/<[^>]+>/g, "").trim().length > 200);
}

async function loadBook(id) {
  const book = await host.fetchJSON(`${API}/${encodeURIComponent(id)}`);
  const url = htmlURL(book);
  if (!url) throw new Error("This book has no HTML edition.");
  const res = await host.fetch(url.replace("http://", "https://"));
  return { book, chapters: splitChapters(res.body) };
}

globalThis.source = {
  async search(query, page) {
    const data = await host.fetchJSON(`${API}?search=${encodeURIComponent(query)}&page=${page || 1}`);
    return {
      results: data.results.map((b) => ({
        id: String(b.id),
        title: b.title,
        authors: b.authors.map((a) => a.name),
        coverURL: b.formats["image/jpeg"] || null,
      })),
      hasMore: Boolean(data.next),
    };
  },

  async getWork(id) {
    const b = await host.fetchJSON(`${API}/${encodeURIComponent(id)}`);
    const epub = b.formats["application/epub+zip"];
    return {
      id: String(b.id),
      title: b.title,
      authors: b.authors.map((a) => a.name),
      coverURL: b.formats["image/jpeg"] || null,
      summaryHTML: (b.summaries || [])[0] ? `<p>${b.summaries[0]}</p>` : null,
      url: `https://www.gutenberg.org/ebooks/${b.id}`,
      rating: "General Audiences",
      tags: b.subjects,
      status: "Complete",
      downloads: epub ? { epub: epub.replace("http://", "https://") } : null,
    };
  },

  async getChapters(id) {
    const { chapters } = await loadBook(id);
    return chapters.map((c, i) => ({ id: String(i), title: c.title, number: i + 1 }));
  },

  async getChapterContent(id, chapterId) {
    const { chapters } = await loadBook(id);
    const chapter = chapters[Number(chapterId)];
    if (!chapter) throw new Error("Chapter not found");
    return { type: "text", html: chapter.html };
  },
};
