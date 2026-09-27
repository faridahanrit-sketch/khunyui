// KHUNYUI service worker: makes the site installable and is ready for Web Push (next step).
// It does not cache pages, so every open always shows the latest menu, prices and orders.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: 'คุณยุ้ย', body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'ออเดอร์ใหม่', {
    body: d.body || '', icon: 'icon-192.png', badge: 'icon-192.png', tag: d.tag || 'khunyui-order',
    data: { url: d.url || './#/owner/orders' }
  }));
});
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = new URL(e.notification.data.url, self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) if (c.url.startsWith(self.registration.scope)) { c.navigate(url); return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
