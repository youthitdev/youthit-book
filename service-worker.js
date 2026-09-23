// 한끗독서 서비스 워커.
// 있는 이유는 캐시가 아니라 푸시다 — 아이폰은 홈 화면에 추가된 PWA 에만 푸시를 준다.
const BASE  = '/youthit-book/';
const CACHE = 'hankkut-book-v1';
const ASSETS = [BASE, BASE + 'app.html', BASE + 'manifest.json',
                BASE + 'icon-192.png', BASE + 'icon-512.png'];

self.addEventListener('install', e => {
  // addAll 은 하나만 404 나도 전부 실패한다. 캐시 때문에 설치가 깨지면 푸시도 못 쓴다
  e.waitUntil(caches.open(CACHE).then(c => Promise.allSettled(ASSETS.map(u => c.add(u)))));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks =>
    Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});

// 네트워크 우선. 한 파일짜리 앱이라 캐시가 앞서면 고친 게 안 보인다 —
// 캐시는 오프라인일 때만 꺼낸다
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  if (!e.request.url.startsWith(self.location.origin)) return;
  e.respondWith(
    fetch(e.request).then(res => {
      const clone = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, clone));
      return res;
    }).catch(() => caches.match(e.request))
  );
});

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; }
  catch { d = { title: '한끗독서', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || '한끗독서', {
    body:  d.body || '',
    icon:  BASE + 'icon-192.png',
    badge: BASE + 'icon-192.png',
    data:  { url: d.url || BASE + 'app.html' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || BASE + 'app.html';
  const pick = k => { const m = url.match(new RegExp('[?&]' + k + '=([\\w-]+)')); return m ? m[1] : null; };
  const nav = { tab: pick('tab'), routine: pick('routine') };
  e.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) {
      if (c.url.includes('/youthit-book') && 'focus' in c) {
        // Client.navigate() 는 아이폰에서 초점만 옮기고 화면은 그대로인 일이 있다.
        // 열려 있으면 페이지에 시켜서 직접 화면을 바꾼다
        if (nav.tab || nav.routine) c.postMessage({ type: 'notif-navigate', ...nav });
        return c.focus();
      }
    }
    return clients.openWindow(url);
  }));
});
