/* Service worker.

   Strategy by resource kind:
   - App shell (HTML/CSS/JS/icons): cache-first, refreshed in the background.
     The app must open instantly in a basement with no signal.
   - API GETs: network-first with a cache fallback, so a cold pocket shows the
     last known "오늘" instead of an error page.
   - API writes: never cached, never queued here — uploads go through the
     IndexedDB outbox in the page, which survives a tab close. */

const VERSION = "sikpan-v1";
const SHELL = [
  "/app/",
  "/app/index.html",
  "/app/css/app.css",
  "/app/js/app.mjs",
  "/app/js/api.mjs",
  "/app/js/ui.mjs",
  "/app/js/outbox.mjs",
  "/app/icons/icon-192.png",
  "/manifest.webmanifest",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(VERSION)
      .then((cache) => cache.addAll(SHELL))
      .then(() => self.skipWaiting())
      .catch(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== location.origin) return;

  if (url.pathname.startsWith("/api/")) {
    event.respondWith(networkFirst(request));
    return;
  }
  event.respondWith(cacheFirst(request));
});

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) {
    // Refresh in the background; the user sees the cached copy immediately.
    fetch(request)
      .then((res) => res.ok && caches.open(VERSION).then((c) => c.put(request, res)))
      .catch(() => {});
    return cached;
  }
  try {
    const res = await fetch(request);
    if (res.ok) {
      const clone = res.clone();
      caches.open(VERSION).then((c) => c.put(request, clone));
    }
    return res;
  } catch {
    return (await caches.match("/app/index.html")) || Response.error();
  }
}

async function networkFirst(request) {
  try {
    const res = await fetch(request);
    if (res.ok) {
      const clone = res.clone();
      caches.open(VERSION).then((c) => c.put(request, clone));
    }
    return res;
  } catch {
    const cached = await caches.match(request);
    if (cached) return cached;
    return new Response(
      JSON.stringify({ error: "offline", message: "오프라인입니다." }),
      { status: 503, headers: { "Content-Type": "application/json" } },
    );
  }
}
