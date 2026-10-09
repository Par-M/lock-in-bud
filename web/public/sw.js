const CACHE = "lock-in-public-v2";
const PUBLIC = ["/offline.html", "/icon.svg", "/icon-192.png", "/icon-512.png", "/apple-icon.png"];
// Turbopack uses 13-character base-36 hashes; webpack uses hexadecimal hashes.
const STATIC = /^\/_next\/static\/(?:[^/]+\/)*(?:[a-z0-9_-]{13}|turbopack-[a-z0-9_-]{13}|[^/]*[a-f0-9]{8,}[^/]*)\.(?:js|css)$/i;

function publicResponse(response, type) {
  return response.ok && !response.redirected && response.type === "basic" &&
    !/\b(?:private|no-store)\b/i.test(response.headers.get("Cache-Control") || "") &&
    type.test(response.headers.get("Content-Type") || "");
}
function assetType(path) {
  return path.endsWith(".css") ? /^text\/css\b/i : /^(?:text|application)\/(?:x-)?javascript\b/i;
}
function publicRequest(path) {
  return new Request(new URL(path, self.location.origin), { credentials: "omit", cache: "reload", redirect: "error" });
}

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await cache.addAll(PUBLIC.map(publicRequest));
    // Only '/' is a public, statically rendered shell. Never cache a navigation
    // response with cookies, RSC headers, query parameters, or another route.
    const shell = await fetch(publicRequest("/"));
    if (!publicResponse(shell, /^text\/html\b/i)) throw new Error("Public app shell is unavailable");
    const html = await shell.clone().text();
    const assets = new Set();
    for (const match of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
      const url = new URL(match[1].replaceAll("&amp;", "&"), self.location.origin);
      if (url.origin === self.location.origin && !url.search && STATIC.test(url.pathname)) assets.add(url.pathname);
    }
    // Initial scripts may have loaded before this worker took control.
    await Promise.all([...assets].map(async path => {
      const response = await fetch(publicRequest(path));
      if (!publicResponse(response, assetType(path))) throw new Error("Public app asset is unavailable");
      await cache.put(path, response);
    }));
    await cache.put("/", shell);
    await self.skipWaiting();
  })());
});
self.addEventListener("activate", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    for (const key of await caches.keys()) {
      if (key === CACHE || !/^lock-in-public-v\d+$/.test(key)) continue;
      const previous = await caches.open(key);
      for (const request of await previous.keys()) {
        const url = new URL(request.url);
        if (url.origin !== self.location.origin || url.search || !(PUBLIC.includes(url.pathname) || STATIC.test(url.pathname))) continue;
        const response = await previous.match(request);
        if (response && publicResponse(response, STATIC.test(url.pathname) ? assetType(url.pathname) : /./) && !await cache.match(request)) {
          await cache.put(request, response);
        }
      }
      await caches.delete(key);
    }
    // Account snapshots and outboxes live in IndexedDB and are never migrated here.
    await self.clients.claim();
  })());
});
self.addEventListener("fetch", event => {
  const request = event.request;
  const url = new URL(event.request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin || url.pathname === "/api" || url.pathname.startsWith("/api/") ||
    url.searchParams.has("_rsc") || request.headers.has("RSC") || request.headers.has("Next-Router-State-Tree") ||
    request.headers.has("Next-Router-Prefetch") || request.headers.has("Next-Router-Segment-Prefetch") ||
    /text\/x-component/i.test(request.headers.get("Accept") || "")) return;
  if (request.mode === "navigate") {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const shell = url.pathname === "/" && !url.search;
      try {
        const response = await fetch(shell ? publicRequest("/") : request);
        if (response.ok) {
          if (shell && publicResponse(response, /^text\/html\b/i)) await cache.put("/", response.clone()).catch(() => {});
          return response;
        }
        if (response.status < 500) return response;
      } catch { /* A lost connection falls back only to public HTML. */ }
      return (shell && await cache.match("/")) || await cache.match("/offline.html") || Response.error();
    })());
  } else if (!url.search && (PUBLIC.includes(url.pathname) || STATIC.test(url.pathname))) {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const cached = await cache.match(url.pathname);
      if (cached) return cached;
      const response = await fetch(publicRequest(url.pathname));
      if (publicResponse(response, STATIC.test(url.pathname) ? assetType(url.pathname) : /./)) {
        await cache.put(url.pathname, response.clone()).catch(() => {});
      }
      return response;
    })());
  }
});
