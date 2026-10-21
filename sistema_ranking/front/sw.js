/*
 * Service worker de Ranking Digital (PWA).
 * - Nunca guarda datos ni respuestas de la API: todo lo que viene de la base se pide siempre al servidor.
 * - Primero la red para todo; solo si el servidor no responde (apagado o arrancando) muestra apagado.html,
 *   que se reintenta sola y entra apenas el sistema esté listo.
 */
const CACHE = 'ranking-digital-v1';
const BASICOS = ['apagado.html', 'manifest.webmanifest', 'iconos/icono-192.png', 'iconos/icono-512.png', 'iconos/icono-32.png'];
const API = ['/rest/', '/rpc/', '/auth/', '/storage/', '/jobs/', '/health'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(BASICOS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((claves) => Promise.all(claves.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return;
  if (API.some((p) => url.pathname.startsWith(p))) return;          // datos: siempre del servidor, sin guardar
  if (e.request.mode === 'navigate') {
    e.respondWith(fetch(e.request).catch(() => caches.match('apagado.html')));
    return;
  }
  e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));
});
