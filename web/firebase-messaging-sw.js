// Firebase Cloud Messaging service worker for the PWA.
//
// This file MUST live at the site root (served as /firebase-messaging-sw.js)
// or the Firebase Messaging SDK cannot find it. It is registered explicitly
// from index.html (after the existing `controllerchange` listener) rather
// than left to auto-registration, because Flutter web already installs its
// own service worker at /flutter_service_worker.js and the two must coexist
// under different scopes.
//
// Config is duplicated here on purpose: service workers cannot import the
// main app's Dart-compiled Firebase config, so if you rotate the web app
// credentials in lib/firebase_options_prod.dart you MUST update the
// firebaseConfig block below too.

// Use the compat SDK — required for `firebase.messaging()` inside a SW.
// Pin the version so a future SDK bump can't silently break background push.
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyCGA1Tq3uN2pzj_U2IfJn_KoE3Ry3VEQnw',
  appId: '1:846580817724:web:018bd4b58b1d837d98c839',
  messagingSenderId: '846580817724',
  projectId: 'pushka-app-ioel',
  authDomain: 'pushka-app-ioel.firebaseapp.com',
  storageBucket: 'pushka-app-ioel.firebasestorage.app',
});

const messaging = firebase.messaging();

// Background message handler. Foreground messages are handled by the Flutter
// side via FirebaseMessaging.onMessage — this fires only when the PWA tab is
// not focused (or is closed on Android; iOS PWAs only deliver in background).
messaging.onBackgroundMessage((payload) => {
  const notif = payload.notification || {};
  const data = payload.data || {};

  const title = notif.title || data.title || 'Pushka';
  const options = {
    body: notif.body || data.body || '',
    icon: notif.icon || '/icons/Icon-192.png',
    badge: '/icons/Icon-192.png',
    // Preserve any deep-link target (e.g. /join/<slug>) for the click handler.
    data: {
      click_action: data.click_action || notif.click_action || '/',
      ...data,
    },
  };

  self.registration.showNotification(title, options);
});

// Focus an existing PWA tab if we have one, otherwise open a new one at the
// click_action route. Without this the notification just dismisses.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.click_action) || '/';

  event.waitUntil((async () => {
    const allClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of allClients) {
      // Same-origin tab already open — focus it and navigate.
      if ('focus' in client) {
        try {
          if ('navigate' in client) await client.navigate(target);
        } catch (_) {}
        return client.focus();
      }
    }
    if (self.clients.openWindow) {
      return self.clients.openWindow(target);
    }
  })());
});
