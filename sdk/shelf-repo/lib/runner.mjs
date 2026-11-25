import vm from "node:vm";
import { readFile } from "node:fs/promises";
import path from "node:path";

/**
 * Runs a source in a Node vm context with the same `host` API the app provides,
 * so authors can test without a phone. This is a development tool, not a security
 * boundary; the app's sandbox is JavaScriptCore.
 */
export async function loadSource(sourceDir, { settings = {}, fetchImpl = globalThis.fetch, log = console.error } = {}) {
  const manifest = JSON.parse(await readFile(path.join(sourceDir, "manifest.json"), "utf8"));
  const script = await readFile(path.join(sourceDir, "main.js"), "utf8");
  const allowed = (url) => {
    const u = new URL(url);
    if (!["https:", "http:"].includes(u.protocol)) return false;
    const host = u.hostname.toLowerCase();
    return manifest.domains.some((d) => (d.startsWith("*.") ? host === d.slice(2) || host.endsWith("." + d.slice(2)) : host === d));
  };

  let cheerio = null;
  const host = Object.freeze({
    async fetch(req) {
      if (typeof req === "string") req = { url: req };
      if (!allowed(req.url)) throw new Error(`The source tried to reach ${new URL(req.url).hostname}, which it didn't declare.`);
      const res = await fetchImpl(req.url, { method: req.method ?? "GET", headers: { "User-Agent": "Shelfbound/0.1 (shelf-repo)", ...(req.headers ?? {}) }, body: req.body });
      return { status: res.status, url: res.url || req.url, headers: Object.fromEntries(res.headers ?? []), body: await res.text() };
    },
    async fetchJSON(req) {
      const res = await host.fetch(req);
      if (res.status < 200 || res.status >= 300) throw new Error("HTTP " + res.status + " for " + res.url);
      return JSON.parse(res.body);
    },
    select(html, selector) {
      if (!cheerio) throw new Error("host.select needs the optional 'cheerio' package: npm install cheerio");
      const $ = cheerio.load(String(html));
      return $(selector).toArray().map((el) => ({ text: $(el).text().trim().replace(/\s+/g, " "), html: $(el).html() ?? "", outerHTML: $.html(el), attrs: { ...el.attribs } }));
    },
    log: (...p) => log(`[${manifest.id}]`, ...p),
    settings: Object.freeze({ get: (k) => settings[k] ?? null }),
  });
  try { cheerio = await import("cheerio"); } catch { /* optional */ }

  const context = vm.createContext({ host, console: { log: host.log, warn: host.log, error: host.log } });
  vm.runInContext(script, context, { filename: path.join(sourceDir, "main.js"), timeout: 1000 });
  const source = context.source;
  for (const fn of ["search", "getWork", "getChapters", "getChapterContent"]) {
    if (typeof source?.[fn] !== "function") throw new Error(`Source must define source.${fn}`);
  }
  // Round-trip through JSON so results look exactly like what the app receives.
  const call = async (fn, ...args) => JSON.parse(JSON.stringify(await source[fn](...args)));
  return { manifest, call };
}
