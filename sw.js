/* HadirKuy — Service Worker (PWA offline)
   • Kerangka aplikasi & pustaka CDN disimpan agar aplikasi tetap terbuka tanpa sinyal.
   • Permintaan ke Supabase TIDAK pernah disimpan (data absensi selalu langsung ke server;
     saat offline, aplikasi menyimpan absen di antrean dan mengirimnya belakangan).
   Naikkan VERSI setiap kali index.html diperbarui agar HP mengambil versi terbaru.
   Created by AN1MO LAB SQUAD */
const VERSI = 'hadirkuy-v3.0.0';
const INTI = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png'];
const CDN = [
  'https://unpkg.com/@phosphor-icons/web@2.1.1',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
  'https://unpkg.com/html5-qrcode@2.3.8/html5-qrcode.min.js',
  'https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.min.js',
];

self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const c = await caches.open(VERSI);
    await c.addAll(INTI);
    await Promise.all(CDN.map(u => c.add(new Request(u, { mode: 'no-cors' })).catch(() => {})));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== VERSI) await caches.delete(k);
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co') || url.hostname.endsWith('supabase.in') || url.hostname.endsWith('fonnte.com')) return;

  // Halaman: utamakan jaringan (agar versi terbaru), cadangan dari cache
  if (req.mode === 'navigate') {
    e.respondWith((async () => {
      try {
        const res = await fetch(req);
        const c = await caches.open(VERSI); c.put('./index.html', res.clone());
        return res;
      } catch (err) {
        return (await caches.match('./index.html')) || (await caches.match('./')) || Response.error();
      }
    })());
    return;
  }

  // Berkas statis & CDN (skrip, ikon, font): ambil dari cache, perbarui di latar belakang
  e.respondWith((async () => {
    const c = await caches.open(VERSI);
    const ada = await c.match(req);
    const segar = fetch(req).then(res => {
      if (res && (res.ok || res.type === 'opaque')) c.put(req, res.clone());
      return res;
    }).catch(() => null);
    return ada || (await segar) || Response.error();
  })());
});
