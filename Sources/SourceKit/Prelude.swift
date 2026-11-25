/// JavaScript run before every source script. It turns the private native bridge into
/// the small, frozen `host` API that sources are allowed to use, then hides the bridge.
enum Prelude {
    static let script = #"""
    (function () {
      "use strict";
      const native = globalThis.__native;
      delete globalThis.__native;
      const pending = new Map();
      let nextFetch = 0;

      const host = Object.freeze({
        fetch(request) {
          if (typeof request === "string") request = { url: request };
          return new Promise((resolve, reject) => {
            const id = ++nextFetch;
            pending.set(id, { resolve, reject });
            native.fetch(id, JSON.stringify(request));
          });
        },
        async fetchJSON(request) {
          const res = await host.fetch(request);
          if (res.status < 200 || res.status >= 300) throw new Error("HTTP " + res.status + " for " + res.url);
          return JSON.parse(res.body);
        },
        select(html, selector) {
          return JSON.parse(native.select(String(html), String(selector)));
        },
        log(...parts) {
          native.log(parts.map((p) => (typeof p === "string" ? p : JSON.stringify(p))).join(" "));
        },
        // For a bot check the app can't detect by itself: the app asks the person to open
        // this page in a browser and pass the check, then retries.
        needsBrowserVerification(url) {
          native.verify(String(url));
          throw new Error("Open " + url + " in the browser to continue.");
        },
        // Filter kinds this app can show. Apps before 0.4 had only the first three, and
        // no list here, so a source offers the rest only when they're listed.
        filterTypes: Object.freeze(["select", "multi", "toggle", "text", "range", "tags"]),
        settings: Object.freeze({
          get(key) {
            const value = native.setting(String(key));
            return value === undefined ? null : value;
          },
        }),
      });

      Object.defineProperty(globalThis, "host", { value: host, writable: false, configurable: false });
      globalThis.console = Object.freeze({ log: host.log, warn: host.log, error: host.log });

      Object.defineProperty(globalThis, "__resolveFetch", {
        value(id, ok, payload) {
          const p = pending.get(id);
          if (!p) return;
          pending.delete(id);
          if (ok) p.resolve(JSON.parse(payload));
          else p.reject(new Error(payload));
        },
      });

      Object.defineProperty(globalThis, "__call", {
        value(callId, name, argsJSON) {
          Promise.resolve()
            .then(() => {
              const source = globalThis.source;
              if (!source || typeof source[name] !== "function") {
                throw new Error("Source does not implement " + name);
              }
              return source[name](...JSON.parse(argsJSON));
            })
            .then(
              (result) => native.done(callId, true, JSON.stringify(result === undefined ? null : result)),
              (error) => native.done(callId, false, String((error && error.message) || error))
            );
        },
      });
    })();
    """#
}
