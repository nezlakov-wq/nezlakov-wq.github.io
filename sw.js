self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
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
