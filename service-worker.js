// 한끗독서 서비스 워커.
// 있는 이유는 캐시가 아니라 푸시다 — 아이폰은 홈 화면에 추가된 PWA 에만 푸시를 준다.
// 주소를 박아 두지 않는다. 등록 범위에서 뽑으면 /youthit-book/ 이든 / 이든
// 그대로 돈다 — 도메인을 갈아도 이 파일을 안 고쳐도 된다
const BASE  = new URL(self.registration.scope).pathname;
const CACHE = 'hankkut-book-v4';

// 알림함(notifications.link)에는 옛 경로가 열여섯 군데 적혀 있다.
// 주소가 바뀌어도 열리도록 앞머리를 떼고 지금 BASE 에 다시 붙인다
function here(u) {
  if (!u) return BASE + 'app.html';
  try {
    const p = new URL(u, self.registration.scope);
    if (p.origin !== self.location.origin) return u;   // 바깥 주소는 건드리지 않는다
    const rest = p.pathname.replace(/^\/youthit-book\//, '').replace(/^\//, '');
    return BASE + (rest || 'app.html') + p.search + p.hash;
  } catch { return BASE + 'app.html'; }
}
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
// 캐시는 오프라인일 때만 꺼낸다.
//
// ⚠️ 그런데 「네트워크 우선」만으로는 모자랐다. 깃허브 페이지스가
//    `cache-control: max-age=600` 을 준다. 그러면 이 fetch 자체를
//    **브라우저가 제 캐시에서 가로채** 10분 동안 옛 파일을 내준다.
//    고쳐서 올려도 폰에선 그대로였던 게 이 때문이다.
//    문서는 늘 서버에 물어본다 — ETag 가 같으면 304 라 사실상 공짜다
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  if (!e.request.url.startsWith(self.location.origin)) return;
  const isDoc = e.request.mode === 'navigate' || e.request.destination === 'document';
  const req = isDoc
    ? new Request(e.request.url, { cache: 'no-cache', credentials: 'same-origin' })
    : e.request;
  e.respondWith(
    fetch(req).then(res => {
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
  e.waitUntil((async () => {
    await self.registration.showNotification(d.title || '한끗독서', {
      body:  d.body || '',
      icon:  BASE + 'icon-192.png',
      badge: BASE + 'icon-192.png',
      data:  { url: here(d.url) },
    });
    // 열려 있는 화면은 🔔 목록을 앱 켜질 때 한 번만 읽는다.
    // 알려주지 않으면 배너만 오고 종은 그대로라, 앱을 꺼다 켜야 숫자가 붙는다
    const list = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of list) c.postMessage({ type: 'notif-new' });
  })());
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = here(e.notification.data && e.notification.data.url);
  const pick = k => { const m = url.match(new RegExp('[?&]' + k + '=([\\w-]+)')); return m ? m[1] : null; };
  const nav = { tab: pick('tab'), routine: pick('routine'), cert: pick('cert') };
  e.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) {
      if (c.url.startsWith(self.registration.scope) && 'focus' in c) {
        // Client.navigate() 는 아이폰에서 초점만 옮기고 화면은 그대로인 일이 있다.
        // 열려 있으면 페이지에 시켜서 직접 화면을 바꾼다
        if (nav.tab || nav.routine || nav.cert) c.postMessage({ type: 'notif-navigate', ...nav });
        // 관리자 화면은 #탭 으로 간다. 열려 있으면 주소만 바꿔 주면 된다
        c.postMessage({ type: 'notif-open', url });
        return c.focus();
      }
    }
    return clients.openWindow(url);
  }));
});
