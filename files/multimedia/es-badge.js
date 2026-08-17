/* es-badge.js — insignias de idioma (ES/LAT/SUB/EN) para Jellyseerr.
 *
 * Inyectado vía ingress-nginx (sub_filter) en las respuestas HTML de
 * jellyseerr.elarreglador.eu. Muestra la DISPONIBILIDAD de idiomas ANTES de
 * descargar: consulta el proxy same-origin /es-badge-api/ (contenedor api del
 * pod es-badge), que busca los releases reales en los indexadores directos de
 * Prowlarr (Torrent9, LimeTorrents, Torrent Downloads) y clasifica por nombre.
 *
 * Insignias por tarjeta (todas las que apliquen):
 *   ES  — existe un release con audio en castellano (doblaje/dual/multi)
 *   LAT — existe un release con audio latino
 *   SUB — existe un release con subtítulos en castellano (VOSE/VOS/subs)
 *   EN  — existe un release con audio en inglés
 *
 * Extracción del título/id por tarjeta:
 *   1) El overlay que React monta al hacer hover (a[href^="/movie|/tv"] +
 *      [data-testid="title-card-title"]).
 *   2) Interceptación de XMLHttpRequest y window.fetch: se capturan las
 *      respuestas JSON de /api/v1/discover y /api/v1/search (mismo dominio,
 *      mismas cookies) y se construye un mapa posterPath -> { tmdbId,
 *      mediaType, title }. Las tarjetas se resuelven por la URL del <img>
 *      (póster de TMDB). Esto cubre las tarjetas que aún no han sido
 *      "hovereadas", que son la mayoría. Jellyseerr usa XHR (axios) para su
 *      API, por eso se interceptan ambos transportes.
 *
 * Render: barra inferior derecha sobre la tarjeta. Cola FIFO (1 petición a la
 * vez) + solo tarjetas visibles + caché en el pod.
 *
 * Debug: añadir ?es-debug=1 a la URL para ver logs de consola y el estado en
 * window.__esBadge.
 */
(function () {
  'use strict';

  var QUEUE = [];          // trabajos pendientes { card, key }
  var BUSY = false;        // una petición a la vez
  var SEEN = new WeakSet(); // tarjetas ya encoladas
  var DONE = {};           // 'mediaType:tmdbId' ya consultados
  var FLAGS = {};          // 'mediaType:tmdbId' -> flags (para pintar duplicados)
  var WAITING = {};        // 'mediaType:tmdbId' -> [card] duplicados en espera
  var POSTERS = {};        // posterPath -> { tmdbId, mediaType, title }
  var DEBUG = /[?&]es-debug=1/.test(window.location.search);

  function log() {
    if (DEBUG && window.console) {
      window.console.log.apply(window.console, ['[es-badge]'].concat([].slice.call(arguments)));
    }
  }

  // --- Captura de respuestas de la API de Jellyseerr ------------------------

  function onApiJson(data) {
    var results = data && data.results;
    if (!Array.isArray(results)) return;
    var added = 0;
    for (var i = 0; i < results.length; i++) {
      var it = results[i];
      if (!it || typeof it.id === 'undefined' || !it.mediaType || !it.posterPath) continue;
      var title = it.title || it.name || '';
      if (!title) continue;
      if (!POSTERS[it.posterPath]) {
        POSTERS[it.posterPath] = {
          tmdbId: String(it.id),
          mediaType: it.mediaType,
          title: title
        };
        added++;
      }
    }
    if (added > 0) {
      log('pósters capturados', added, '| total', Object.keys(POSTERS).length);
      scan(); // tarjetas que antes no resolvían ahora sí
    }
  }

  function interceptFetch() {
    if (!window.fetch) return;
    var orig = window.fetch.bind(window);
    window.fetch = function (input, init) {
      var url = typeof input === 'string' ? input : input && input.url;
      if (url && /\/api\/v1\/(discover|search)/.test(url)) {
        return orig(input, init).then(function (res) {
          try {
            res.clone().json().then(onApiJson).catch(function () {});
          } catch (e) {
            /* cuerpo no reutilizable: se ignora */
          }
          return res;
        });
      }
      return orig(input, init);
    };
    log('fetch interceptado');
  }

  // Jellyseerr usa XMLHttpRequest (axios) para su API, no window.fetch, así
  // que sin esta interceptación el mapa de pósters nunca se llena en producción.
  function interceptXhr() {
    if (!window.XMLHttpRequest) return;
    var Open = window.XMLHttpRequest.prototype.open;
    var Send = window.XMLHttpRequest.prototype.send;
    window.XMLHttpRequest.prototype.open = function (method, url) {
      this.__esUrl = String(url);
      return Open.apply(this, arguments);
    };
    window.XMLHttpRequest.prototype.send = function () {
      var self = this;
      var url = self.__esUrl || '';
      if (/\/api\/v1\/(discover|search)/.test(url)) {
        self.addEventListener('load', function () {
          if (self.status !== 200) return;
          try {
            onApiJson(JSON.parse(self.responseText));
          } catch (e) {
            /* cuerpo no JSON: se ignora */
          }
        });
      }
      return Send.apply(this, arguments);
    };
    log('xhr interceptado');
  }

  // --- Identificación de tarjetas ------------------------------------------

  var POSTER_RE = /\/t\/p\/[^/]+\/([^/?]+\.(?:jpe?g|png|webp|avif))/i;

  function posterOf(card) {
    var img = card.querySelector('img');
    if (!img) return null;
    var src = img.getAttribute('src') || img.srcset || '';
    var m = src.match(POSTER_RE);
    return m ? '/' + m[1] : null;
  }

  // Devuelve { tmdbId, mediaType, title } para una tarjeta, o null.
  function cardKey(card) {
    var a = card.querySelector('a[href^="/movie/"], a[href^="/tv/"]');
    if (a) {
      var m = /^\/(movie|tv)\/(\d+)$/.exec(a.getAttribute('href'));
      if (m) {
        var h = card.querySelector('[data-testid="title-card-title"]');
        if (h && h.textContent.trim()) {
          return { tmdbId: m[2], mediaType: m[1], title: h.textContent.trim() };
        }
      }
    }
    var poster = posterOf(card);
    if (poster && POSTERS[poster]) {
      var k = POSTERS[poster];
      return { tmdbId: k.tmdbId, mediaType: k.mediaType, title: k.title };
    }
    return null;
  }

  function enqueue(card) {
    if (SEEN.has(card)) return;
    var key = cardKey(card);
    if (!key) return; // aún sin datos: scan() lo reintentará al capturarlos
    SEEN.add(card);
    var id = key.mediaType + ':' + key.tmdbId;
    if (DONE[id]) {
      // Misma película en varios sliders: una sola consulta, pero se pinta
      // también en esta tarjeta con el resultado ya resuelto (o en espera).
      if (FLAGS[id]) badgeCard(card, FLAGS[id]);
      else (WAITING[id] = WAITING[id] || []).push(card);
      return;
    }
    DONE[id] = true;
    QUEUE.push({ card: card, key: key });
    pump();
  }

  function pump() {
    if (BUSY || QUEUE.length === 0) return;
    var job = QUEUE.shift();
    BUSY = true;
    lookup(job).then(
      function () { BUSY = false; pump(); },
      function () { BUSY = false; pump(); }
    );
  }

  function lookup(job) {
    var key = job.key;
    var id = key.mediaType + ':' + key.tmdbId;
    var url =
      '/es-badge-api/search?mediaType=' + encodeURIComponent(key.mediaType) +
      '&tmdbId=' + encodeURIComponent(key.tmdbId) +
      '&q=' + encodeURIComponent(key.title);
    log('consulta', key.mediaType, key.tmdbId, key.title);
    return fetch(url)
      .then(function (r) {
        if (!r.ok) throw new Error('es-badge-api HTTP ' + r.status);
        return r.json();
      })
      .then(function (flags) {
        log('flags', key.tmdbId, flags);
        if (flags && typeof flags === 'object') {
          FLAGS[id] = flags; // cache para tarjetas duplicadas del mismo título
          badgeCard(job.card, flags);
          var w = WAITING[id];
          if (w) {
            for (var i = 0; i < w.length; i++) badgeCard(w[i], flags);
            delete WAITING[id];
          }
        }
      })
      .catch(function (e) {
        log('error', key.tmdbId, e && e.message);
      });
  }

  // Inserta las insignias en una tarjeta [data-testid="title-card"].
  function badgeCard(card, flags) {
    var any = flags && (flags.ES || flags.LAT || flags.SUB || flags.EN);
    if (!any || card.querySelector('.es-badge-bar')) return;

    var bar = document.createElement('div');
    bar.className = 'es-badge-bar';

    function add(kind, label) {
      if (!flags[kind]) return;
      var b = document.createElement('span');
      b.className = 'es-badge ' + 'es-badge-' + kind.toLowerCase();
      b.textContent = label;
      bar.appendChild(b);
    }
    add('ES', 'ES');
    add('LAT', 'LAT');
    add('SUB', 'SUB');
    add('EN', 'EN');

    card.appendChild(bar);
  }

  function scan() {
    var cards = document.querySelectorAll('[data-testid="title-card"]');
    for (var i = 0; i < cards.length; i++) {
      var card = cards[i];
      if (isVisible(card)) enqueue(card);
    }
  }

  function isVisible(el) {
    if (!el.offsetParent && el.getBoundingClientRect().height === 0) return false;
    var r = el.getBoundingClientRect();
    var vh = window.innerHeight || document.documentElement.clientHeight;
    return r.top < vh && r.bottom > 0;
  }

  function start() {
    var style = document.createElement('style');
    style.textContent =
      '[data-testid="title-card"]{position:relative;}' +
      '.es-badge-bar{' +
      'position:absolute;z-index:60;right:6px;bottom:6px;display:flex;' +
      'gap:3px;pointer-events:none;}' +
      '.es-badge{' +
      'font-size:10px;font-weight:700;line-height:1;padding:3px 5px;' +
      'border-radius:4px;color:#fff;letter-spacing:.03em;' +
      'box-shadow:0 1px 3px rgba(0,0,0,.5);}' +
      '.es-badge-es{background:#22c55e;}' +
      '.es-badge-lat{background:#eab308;}' +
      '.es-badge-sub{background:#3b82f6;}' +
      '.es-badge-en{background:#6b7280;}';
    document.head.appendChild(style);

    if (DEBUG) {
      window.__esBadge = {
        posters: function () { return Object.keys(POSTERS).length; },
        done: function () { return Object.keys(DONE).length; },
        pending: function () { return QUEUE.length; },
        waiting: function () {
          return Object.keys(WAITING).reduce(function (n, k) {
            return n + WAITING[k].length;
          }, 0);
        },
        busy: function () { return BUSY; },
        flags: function () { return FLAGS; }
      };
      log('debug activo');
    }

    // Tarjetas visibles inicialmente
    scan();

    var mo = new MutationObserver(scan);
    mo.observe(document.body, { childList: true, subtree: true });

    // Al hacer scroll, encola las tarjetas que entren en viewport
    var last = 0;
    window.addEventListener(
      'scroll',
      function () {
        var now = Date.now();
        if (now - last < 200) return;
        last = now;
        scan();
      },
      { passive: true }
    );
  }

  interceptFetch();
  interceptXhr();

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();