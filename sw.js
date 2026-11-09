self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
// Кеш оболочки приложения: сначала сеть, при отсутствии сети — сохранённая копия.
// Запросы к другим сайтам (Supabase и т.д.) и не-GET не кешируем: данные переписки всегда свежие.
const SHELL_CACHE = 'moonlit-shell-v1';
self.addEventListener('fetch', e => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  e.respondWith((async () => {
    const cache = await caches.open(SHELL_CACHE);
    try {
      const res = await fetch(req);
      if (res && res.ok && res.type === 'basic') cache.put(req, res.clone());
      return res;
    } catch (err) {
      const cached = await cache.match(req) || (req.mode === 'navigate' ? await cache.match('./index.html') || await cache.match('index.html') : null);
      if (cached) return cached;
      throw err;
    }
  })());
});
// Push с сервера: показываем уведомление, если приложение не открыто на экране
self.addEventListener('push', e => {
  e.waitUntil((async () => {
    const cs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (cs.some(c => c.visibilityState === 'visible')) return;
    let data = { title: 'Moonlit', body: 'Новое сообщение', tag: 'moonlit' };
    try { data = { ...data, ...e.data.json() }; } catch (err) {}
    await self.registration.showNotification(data.title, { body: data.body, tag: data.tag, icon: 'icon-192.png', data: { url: data.url || './' } });
  })());
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window' }).then(cs => {
    if (cs.length) return cs[0].focus();
    return self.clients.openWindow('./');
  }));
});
