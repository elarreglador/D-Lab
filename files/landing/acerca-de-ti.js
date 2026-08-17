/**
 * acerca-de-ti.js — «Acerca de ti»
 *
 * Dossier de huella digital del visitante. Leemos el navegador del visitante,
 * deducimos lo que podemos y se lo narramos en claro, sin pedir permiso:
 * así funciona la web sin cookies, y cualquier otro sitio puede hacerlo.
 *
 * Nada de lo que aquí se mide se envía al servidor D-Lab: todo corre en el
 * navegador del visitante. Las únicas llamadas de red son, por transparencia,
 * la geolocalización por IP (ipwho.is) y los servidores STUN de Google usados
 * por WebRTC; se advierte de ambas en la nota al pie.
 *
 * Este código reinterpreta (en español) la parte técnica del proyecto
 * open-source "cookie" de Kuber Mehta (github.com/Kuberwastaken/cookie),
 * cuyo aviso de licencia se mantiene.
 */
(() => {
  'use strict';

  const ROOT = document.getElementById('lectura-visitante');
  if (!ROOT) return;

  /** El dossier se pinta a demanda tras el botón: los sueños pasan a ser sincrónicos. */
  let instant = false;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /** FNV-1a de 32 bits, pequeño y sin dependencias (adecuado para un hash de visualización). */
  function hash(input) {
    let h = 0x811c9dc5;
    for (let i = 0; i < input.length; i++) {
      h ^= input.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h.toString(16).padStart(8, '0');
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]
    ));
  }

  /** *énfasis* en el texto de las afirmaciones → <em>. */
  function markup(text) {
    return esc(text).replace(/\*([^*]+)\*/g, '<em>$1</em>');
  }

  const sleep = (ms) => (instant ? Promise.resolve() : new Promise((r) => setTimeout(r, ms)));

  const reduceMotion = () =>
    typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

  const beat = () => (reduceMotion() ? 0 : 40);

  /** Señal cruda: una medida del navegador con entropía estimada en bits. */
  function sig(id, label, value, extra = {}) {
    return { id, label, value, ...extra };
  }

  const signals = {}; // SignalMap: id → signal

  const num = (id) => (typeof signals[id]?.value === 'number' ? signals[id].value : undefined);
  const str = (id) => (typeof signals[id]?.value === 'string' && signals[id].value ? signals[id].value : undefined);

  function put(id, label, value, entropy) {
    if (value == null || value === '') return;
    signals[id] = { id, label, value, entropy };
  }

  const display = (id) => {
    const s = signals[id];
    if (!s) return null;
    if (s.display != null && s.display !== '') return s.display;
    if (s.value == null) return null;
    if (typeof s.value === 'object') {
      try { return JSON.stringify(s.value); } catch { return String(s.value); }
    }
    return String(s.value);
  };

  const trunc = (s2, n) => (s2.length > n ? `${s2.slice(0, n)}…` : s2);

  /** Entropía total tipo Shannon, con saturación: las señales correlacionadas no suman de forma lineal. */
  function totalEntropy() {
    let sum = 0;
    for (const s of Object.values(signals)) {
      if (s.error || typeof s.entropy !== 'number') continue;
      sum += s.entropy;
    }
    return sum <= 20 ? sum : 20 + Math.log2(sum - 19);
  }

  /** Huella de dispositivo estable a partir de señales que no cambian entre visitas. */
  function deviceFingerprint() {
    const STABLE = [
      'gpu.renderer', 'canvas.hash', 'audio.hash', 'fonts.hash',
      'display.resolution', 'display.pixelRatio', 'hw.cores', 'hw.memory',
      'voices.hash', 'codecs.hash',
    ];
    const parts = STABLE.map((id) => `${id}=${display(id) ?? ''}`).filter((p) => !p.endsWith('='));
    const os = osFromUA();
    if (os) parts.push(`os=${os}`);
    return hash(parts.join('|'));
  }

  const ctrl = new AbortController();
  addEventListener('beforeunload', () => ctrl.abort());

  // ---------------------------------------------------------------------------
  // Sondas pasivas (sin permisos, sin efectos secundarios)
  // ---------------------------------------------------------------------------

  /** Plataforma, navegador e idioma. */
  async function probePlatform() {
    const out = [];
    const n = navigator;
    out.push(sig('ua', 'User-Agent', n.userAgent, { entropy: 10 }));
    out.push(sig('platform', 'navigator.platform', n.platform || null, { entropy: 2 }));
    out.push(sig('langs', 'Idiomas', n.languages, {
      display: (n.languages || []).join(', '), entropy: 4,
    }));
    out.push(sig('dnt', 'Do Not Track', n.doNotTrack ?? null, { entropy: 1 }));
    out.push(sig('gpc', 'Global Privacy Control',
      n.globalPrivacyControl ?? null, { entropy: 1 }));
    out.push(sig('cookies', 'Cookies habilitadas', !!n.cookieEnabled));
    out.push(sig('webdriver', 'navigator.webdriver', n.webdriver ?? false, { entropy: 2 }));

    // Client hints de alta entropía: el navegador los regala sin permiso.
    try {
      if (n.userAgentData?.getHighEntropyValues) {
        const hints = await n.userAgentData.getHighEntropyValues([
          'architecture', 'bitness', 'model', 'platformVersion',
          'fullVersionList', 'uaFullVersion', 'wow64',
        ]);
        if (hints.architecture) out.push(sig('arch', 'Arquitectura CPU', hints.architecture, { entropy: 1 }));
        if (hints.bitness) out.push(sig('bitness', 'Bitness', hints.bitness));
        if (hints.model) out.push(sig('model', 'Modelo de dispositivo', hints.model, { entropy: 3 }));
        if (hints.platformVersion) out.push(sig('osVer', 'Versión del SO', hints.platformVersion, { entropy: 3 }));
        if (hints.fullVersionList?.length) {
          out.push(sig('brVer', 'Versión completa del navegador',
            hints.fullVersionList.map((b) => `${b.brand} ${b.version}`).join(', '), { entropy: 4 }));
        }
      }
      if (n.userAgentData?.platform) {
        out.push(sig('uadPlatform', 'Plataforma UA-CH', n.userAgentData.platform));
        out.push(sig('mobile', 'Móvil', !!n.userAgentData.mobile));
      }
    } catch { /* hints denegados */ }

    return out;
  }

  /** Pantalla: geometría, densidad, orientación y refresco real por rAF. */
  async function probeDisplay() {
    const out = [];
    const s = screen;
    out.push(sig('display.resolution', 'Resolución de pantalla', [s.width, s.height], {
      display: `${s.width} × ${s.height}`, entropy: 4.8,
    }));
    out.push(sig('display.pixelRatio', 'Density pixel ratio', devicePixelRatio, { entropy: 1.5 }));
    out.push(sig('display.colorDepth', 'Profundidad de color', s.colorDepth));
    out.push(sig('display.viewport', 'Viewport', [innerWidth, innerHeight], {
      display: `${innerWidth} × ${innerHeight}`,
    }));
    out.push(sig('display.orientation', 'Orientación', s.orientation?.type ?? null));

    // Varios monitores: un booleano que el navegador suelta sin permiso.
    try {
      if (s.isExtended) out.push(sig('display.multiMonitor', 'Multi-monitor', true, { entropy: 1.2 }));
    } catch { /* no soportado */ }

    // Refresco real: mediana de los deltas de rAF, resiste frames perdidos.
    const hz = await new Promise((resolve) => {
      const times = [];
      let last = performance.now();
      let frames = 0;
      const tick = (now) => {
        times.push(now - last);
        last = now;
        if (++frames < 24) requestAnimationFrame(tick);
        else {
          const sorted = times.slice(2).sort((a, b) => a - b);
          const median = sorted[Math.floor(sorted.length / 2)] || 16.7;
          resolve(Math.round(1000 / median));
        }
      };
      requestAnimationFrame(tick);
      setTimeout(() => resolve(0), 900);
    });
    if (hz) out.push(sig('display.refreshHz', 'Frecuencia de refresco', hz, {
      display: `${hz} Hz`, entropy: 1.5,
    }));

    return out;
  }

  /** CPU, memoria, entrada, red y batería. */
  async function probeHardware() {
    const out = [];
    const n = navigator;
    out.push(sig('hw.cores', 'Núcleos de CPU', n.hardwareConcurrency ?? null, { entropy: 2.4 }));
    out.push(sig('hw.memory', 'Memoria (GB, por tramos)', n.deviceMemory ?? null, { entropy: 1.8 }));
    if (n.maxTouchPoints != null) {
      out.push(sig('hw.touch', 'Puntos de contacto máximos', n.maxTouchPoints, { entropy: 0.5 }));
    }
    out.push(sig('hw.hover', 'Con hover', matchMedia('(hover: hover)').matches));

    if (n.connection) {
      out.push(sig('hw.netKind', 'Medio físico', n.connection.type || null));
      out.push(sig('hw.netType', 'Clase de velocidad (effectiveType)',
        n.connection.effectiveType || null));
      out.push(sig('hw.downlink', 'Descarga (Mbps)', n.connection.downlink ?? null));
      out.push(sig('hw.rtt', 'Latencia (ms)', n.connection.rtt ?? null));
      out.push(sig('hw.saveData', 'Save-Data', n.connection.saveData ?? null));
    }

    // Recuentos de dispositivos sin permiso; solo los nombres están vetados.
    try {
      if (n.mediaDevices?.enumerateDevices) {
        const devices = await n.mediaDevices.enumerateDevices();
        const count = (kind) => devices.filter((d) => d.kind === kind).length;
        out.push(sig('hw.cameras', 'Cámaras conectadas', count('videoinput'), { entropy: 1.2 }));
        out.push(sig('hw.mics', 'Micrófonos conectados', count('audioinput'), { entropy: 1.2 }));
        out.push(sig('hw.labels', 'Nombres de dispositivos legibles', devices.some((d) => d.label !== '')));
      }
    } catch { /* no disponible */ }

    try {
      if (n.getBattery) {
        const b = await n.getBattery();
        if (typeof b.level === 'number') {
          out.push(sig('hw.battery', 'Nivel de batería', b.level, {
            display: `${Math.round(b.level * 100)}%`, entropy: 2,
          }));
        }
        if (typeof b.charging === 'boolean') out.push(sig('hw.charging', 'Cargando', b.charging));
      }
    } catch { /* batería vetada */ }

    return out;
  }

  /** Entorno: zona horaria, idioma, hora local y preferencias del sistema. */
  async function probeEnvironment() {
    const dtf = Intl.DateTimeFormat().resolvedOptions();
    const mq = (q) => matchMedia(q).matches;
    const out = [
      sig('env.timezone', 'Zona horaria', dtf.timeZone, { entropy: 3.2 }),
      sig('env.tzOffset', 'Desfase UTC (min)', -new Date().getTimezoneOffset()),
      sig('env.locale', 'Locale', dtf.locale, { entropy: 2 }),
      sig('env.hour', 'Hora local (0-23)', new Date().getHours()),
      sig('env.localTime', 'Hora local', new Date().toString()),
      sig('env.colorScheme', 'Esquema de color', mq('(prefers-color-scheme: dark)') ? 'dark' : 'light'),
      sig('env.reducedMotion', 'Prefiere menos movimiento', mq('(prefers-reduced-motion: reduce)'), { entropy: 1 }),
      sig('env.colorGamut', 'Gamut de color',
        mq('(color-gamut: rec2020)') ? 'rec2020' : mq('(color-gamut: p3)') ? 'p3' : 'srgb'),
      sig('env.hdr', 'Capaz de HDR', mq('(dynamic-range: high)')),
      sig('env.forcedColors', 'Colores forzados', mq('(forced-colors: active)'), { entropy: 1.5 }),
    ];
    return out;
  }

  /** Códecs: buen proxy de la versión de SO y del nivel de hardware. */
  async function probeCodecs() {
    const v = document.createElement('video');
    const a = document.createElement('audio');
    const CANDIDATES = [
      ['h264', 'video/mp4; codecs="avc1.42E01E"', v],
      ['hevc', 'video/mp4; codecs="hvc1.1.6.L93.B0"', v],
      ['av1', 'video/mp4; codecs="av01.0.08M.08"', v],
      ['vp9', 'video/webm; codecs="vp9"', v],
      ['aac', 'audio/mp4; codecs="mp4a.40.2"', a],
      ['flac', 'audio/flac', a],
      ['opus', 'audio/webm; codecs="opus"', a],
    ];
    const support = {};
    for (const [name, type, el] of CANDIDATES) support[name] = el.canPlayType(type) || 'no';
    return [
      sig('codecs.support', 'Códecs', support, {
        display: Object.entries(support).filter(([, r]) => r !== 'no').map(([k]) => k).join(', '),
        entropy: 2.5,
      }),
      sig('codecs.hash', 'Huella de códecs', JSON.stringify(support)),
    ];
  }

  /** Voces de síntesis: señal sonora de SO y de paquetes de idioma. */
  async function probeVoices() {
    if (!('speechSynthesis' in window)) return [];
    const voices = await new Promise((resolve) => {
      const got = speechSynthesis.getVoices();
      if (got.length) return resolve(got);
      const t = setTimeout(() => resolve(speechSynthesis.getVoices()), 600);
      speechSynthesis.onvoiceschanged = () => { clearTimeout(t); resolve(speechSynthesis.getVoices()); };
    });
    const names = voices.map((x) => `${x.name}|${x.lang}`);
    const langs = [...new Set(voices.map((x) => x.lang))].sort();
    return [
      sig('voices.count', 'Voces instaladas', voices.length, { entropy: 2 }),
      sig('voices.langs', 'Idiomas de voz', langs, { display: langs.join(', '), entropy: 3 }),
      sig('voices.hash', 'Lista de voces', names, {
        display: names.slice(0, 8).join(', '), entropy: 5,
      }),
      sig('voices.local', 'Voces locales', voices.filter((x) => x.localService).length),
    ];
  }

  /** GPU vía WebGL, con cotejo en Worker para detectar suplantación. */
  async function probeGpu() {
    const out = [];
    const canvas = document.createElement('canvas');
    const gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
    if (!gl) return out;

    const dbg = gl.getExtension('WEBGL_debug_renderer_info');
    const vendor = dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
    const renderer = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    if (vendor) out.push(sig('gpu.vendor', 'Fabricante GPU', vendor));
    if (renderer) out.push(sig('gpu.renderer', 'GPU', renderer, { entropy: 7 }));
    out.push(sig('gpu.extensions', 'Extensiones WebGL', (gl.getSupportedExtensions() || []).length, {
      display: `${(gl.getSupportedExtensions() || []).length} extensiones`,
    }));

    // Los suplantadores parchean el hilo principal pero se olvidan del Worker.
    const workerRenderer = await new Promise((resolve) => {
      if (typeof Worker === 'undefined' || typeof OffscreenCanvas === 'undefined') { resolve(null); return; }
      const src = `
        self.onmessage = function () {
          try {
            var c = new OffscreenCanvas(64, 64);
            var g = c.getContext('webgl2') || c.getContext('webgl');
            if (!g) { postMessage(null); return; }
            var d = g.getExtension('WEBGL_debug_renderer_info');
            postMessage(d ? g.getParameter(d.UNMASKED_RENDERER_WEBGL) : g.getParameter(g.RENDERER) || null);
          } catch (e) { postMessage(null); }
        };
      `;
      let worker = null;
      let url = null;
      const cleanup = () => { worker?.terminate(); if (url) URL.revokeObjectURL(url); };
      try {
        url = URL.createObjectURL(new Blob([src], { type: 'application/javascript' }));
        worker = new Worker(url);
        const timer = setTimeout(() => { cleanup(); resolve(null); }, 1500);
        worker.onmessage = (ev) => { clearTimeout(timer); cleanup(); resolve(ev.data ?? null); };
        worker.onerror = () => { clearTimeout(timer); cleanup(); resolve(null); };
        worker.postMessage('go');
      } catch { cleanup(); resolve(null); }
    });
    if (workerRenderer != null) {
      out.push(sig('gpu.rendererMismatch', 'GPU distinta en Worker', workerRenderer !== renderer));
    }

    return out;
  }

  /** Huella de canvas 2D (mezcla de fuentes/emoji más formas). */
  async function probeCanvas() {
    const out = [];
    try {
      const c = document.createElement('canvas');
      c.width = 280; c.height = 60;
      const ctx = c.getContext('2d');
      ctx.textBaseline = 'alphabetic';
      ctx.fillStyle = '#f60'; ctx.fillRect(0, 0, 100, 30);
      ctx.fillStyle = '#069';
      ctx.font = '16px "Arial"';
      ctx.fillText('nodurasdecookies 🕵️ CW#$%^&*() 1.0', 4, 20);
      ctx.font = 'italic 12px "Times New Roman"';
      ctx.fillStyle = 'rgba(102, 204, 0, 0.7)';
      ctx.fillText('el rápido zorro marrón salta sobre el perro perezoso', 4, 45);
      ctx.strokeStyle = ctx.createLinearGradient(0, 0, 280, 0);
      ctx.strokeStyle.addColorStop(0, 'magenta');
      ctx.strokeStyle.addColorStop(1, 'cyan');
      ctx.beginPath(); ctx.arc(220, 30, 20, 0, Math.PI * 2); ctx.stroke();
      out.push(sig('canvas.hash', 'Huella de canvas', hash(c.toDataURL()), { entropy: 6 }));
    } catch (err) {
      out.push(sig('canvas.hash', 'Huella de canvas', null, { error: String(err) }));
    }
    try {
      const c2 = document.createElement('canvas');
      c2.width = 200; c2.height = 50;
      const ctx2 = c2.getContext('2d');
      ctx2.textBaseline = 'alphabetic';
      ctx2.font = '24px sans-serif';
      ctx2.fillText('🎨🌍👨‍👩‍👧‍👦🏳️‍🌈', 0, 32);
      out.push(sig('canvas.emojiHash', 'Huella de renderizado de emoji', hash(c2.toDataURL()), { entropy: 3 }));
    } catch (err) {
      out.push(sig('canvas.emojiHash', 'Huella de renderizado de emoji', null, { error: String(err) }));
    }
    return out;
  }

  /** Huella de audio fuera de línea (ruta DSP del SO). */
  async function probeAudio() {
    const out = [];
    try {
      const Ctx = window.OfflineAudioContext || window.webkitOfflineAudioContext;
      if (!Ctx) throw new Error('OfflineAudioContext no disponible');
      const ctx = new Ctx(1, 44100, 44100);
      const osc = ctx.createOscillator();
      osc.type = 'triangle';
      osc.frequency.value = 10000;
      const comp = ctx.createDynamicsCompressor();
      comp.threshold.value = -50; comp.knee.value = 40; comp.ratio.value = 12;
      comp.attack.value = 0; comp.release.value = 0.25;
      osc.connect(comp); comp.connect(ctx.destination); osc.start(0);
      const rendered = await Promise.race([
        ctx.startRendering(),
        new Promise((resolve) => setTimeout(() => resolve(null), 1000)),
      ]);
      if (!rendered) throw new Error('render agotado');
      const data = rendered.getChannelData(0);
      let sum = 0;
      for (let i = 0; i < data.length; i++) sum += Math.abs(data[i]);
      out.push(sig('audio.hash', 'Huella de audio', hash(sum.toString()), { entropy: 5 }));
    } catch (err) {
      out.push(sig('audio.hash', 'Huella de audio', null, { error: String(err) }));
    }
    return out;
  }

  // Lista de fuentes candidatas (Windows/macOS/Linux, software y paquetes de idioma).
  const FONT_CANDIDATES = [
    'Cambria Math', 'Nirmala UI', 'HoloLens MDL2 Assets', 'Segoe UI', 'Segoe Fluent Icons',
    'Segoe MDL2 Assets', 'Segoe UI Symbol', 'Segoe Print', 'Segoe Script', 'Calibri', 'Cambria',
    'Consolas', 'Candara', 'Corbel', 'Ebrima', 'Gabriola', 'Gadugi', 'Javanese Text',
    'Leelawadee UI', 'Malgun Gothic', 'Microsoft Himalaya', 'Microsoft JhengHei',
    'Microsoft New Tai Lue', 'Microsoft PhagsPa', 'Microsoft Tai Le', 'Microsoft Uighur',
    'Microsoft YaHei', 'Microsoft Yi Baiti', 'MingLiU-ExtB', 'Mongolian Baiti', 'MS Gothic',
    'MS Mincho', 'MV Boli', 'Myanmar Text', 'Sitka', 'SimSun', 'SimSun-ExtB', 'Sylfaen',
    'Yu Gothic', 'Yu Mincho', 'Helvetica Neue', 'Luminari', 'Galvji', 'Geneva', 'Menlo',
    '.SF NS', 'Apple Color Emoji', 'Apple SD Gothic Neo', 'Avenir', 'American Typewriter',
    'Andale Mono', 'Arial Hebrew', 'Athelas', 'Baskerville', 'Big Caslon', 'Bodoni 72',
    'Chalkboard SE', 'Charter', 'Cochin', 'Damascus', 'Didot', 'Futura', 'Gill Sans',
    'Hoefler Text', 'Kailasa', 'Kefa', 'Marker Felt', 'Monaco', 'Noteworthy', 'Optima',
    'Palatino', 'Papyrus', 'PingFang SC', 'PingFang TC', 'Savoye LET', 'Skia',
    'Snell Roundhand', 'Superclarendon', 'Zapfino', 'Ubuntu', 'DejaVu Sans',
    'Liberation Sans', 'Noto Color Emoji', 'Cantarell', 'DejaVu Serif', 'DejaVu Sans Mono',
    'Liberation Serif', 'Liberation Mono', 'Noto Sans', 'Noto Serif', 'Droid Sans',
    'FreeSans', 'FreeSerif', 'Nimbus Sans', 'Nimbus Roman', 'Ubuntu Mono', 'Ubuntu Condensed',
    'Roboto', 'Latin Modern Roman', 'Latin Modern Math', 'CMU Serif', 'TeX Gyre Termes',
    'TeX Gyre Heros', 'TeX Gyre Pagella', 'XITS', 'STIX Two Math', 'Bookman Old Style',
    'Book Antiqua', 'Century Gothic', 'Franklin Gothic Medium', 'Perpetua', 'Rockwell',
    'Myriad Pro', 'Minion Pro', 'Trajan Pro', 'Adobe Garamond Pro', 'Adobe Caslon Pro',
    'Bickham Script Pro', 'JetBrains Mono', 'Cascadia Code', 'Fira Code', 'Source Code Pro',
    'Hack', 'Iosevka', 'Victor Mono', 'Meiryo',
  ];

  const FONT_BASELINES = ['monospace', 'sans-serif', 'serif'];
  const FONT_PROBES = ['mmmmmmmmmmlli-.,WQ@#gjpqy0123456789', 'ABCDEFabcdef你好こんにちは한국어'];
  const FONT_SIZE = '72px';
  const FONT_THRESHOLD = 0.75;
  const FONT_SENTINEL = 'ZZName_NoSuchFontEver_9137xQ';

  /** Detección por medición de anchos; devuelve null si el entorno miente. */
  function detectFonts() {
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    const baseline = {};
    for (const base of FONT_BASELINES) {
      baseline[base] = FONT_PROBES.map((s) => { ctx.font = `${FONT_SIZE} ${base}`; return ctx.measureText(s).width; });
    }
    const present = (name) => {
      for (const base of FONT_BASELINES) {
        for (let i = 0; i < FONT_PROBES.length; i++) {
          ctx.font = `${FONT_SIZE} "${name}", ${base}`;
          if (Math.abs(ctx.measureText(FONT_PROBES[i]).width - baseline[base][i]) < FONT_THRESHOLD) return false;
        }
      }
      return true;
    };
    if (present(FONT_SENTINEL)) return null;
    return FONT_CANDIDATES.filter(present);
  }

  /** Fuentes: SO inferido, software instalado y huella de la lista. */
  async function probeFonts() {
    const detected = detectFonts();
    if (detected === null) {
      return [
        sig('fonts.count', 'Fuentes detectadas', 0),
        sig('fonts.impliedOS', 'SO inferido', 'unknown'),
        sig('fonts.__error', 'Fuentes', null, { error: 'detección de fuentes no fiable aquí' }),
      ];
    }
    const set = new Set(detected);
    const sorted = [...detected].sort();

    const buckets = [
      { os: 'Windows', hits: ['Cambria Math', 'Nirmala UI', 'HoloLens MDL2 Assets', 'Segoe UI', 'Segoe Fluent Icons', 'Segoe MDL2 Assets'].filter((f) => set.has(f)) },
      { os: 'macOS', hits: ['Helvetica Neue', 'Luminari', 'Galvji', 'Geneva', 'Menlo', '.SF NS', 'Apple Color Emoji'].filter((f) => set.has(f)) },
      { os: 'Linux', hits: ['Ubuntu', 'DejaVu Sans', 'Liberation Sans', 'Noto Color Emoji', 'Cantarell'].filter((f) => set.has(f)) },
    ];
    buckets.sort((a, b) => b.hits.length - a.hits.length);
    let impliedOS = 'unknown';
    if (buckets[0].hits.length > 0 && buckets[0].hits.length > (buckets[1]?.hits.length ?? 0)) {
      impliedOS = buckets[0].os;
    }
    let impliedOSVersion = null;
    if (set.has('Segoe Fluent Icons')) impliedOSVersion = 'Windows 11';
    else if (set.has('Segoe MDL2 Assets')) impliedOSVersion = 'Windows 10';

    const software = [];
    const latex = ['Latin Modern Roman', 'Latin Modern Math', 'CMU Serif', 'TeX Gyre Termes', 'TeX Gyre Heros', 'TeX Gyre Pagella', 'XITS', 'STIX Two Math'].filter((f) => set.has(f));
    if (latex.length >= 2) software.push({ name: 'LaTeX / TeX Live', fonts: latex, confidence: 'guess' });
    const office = ['Bookman Old Style', 'Book Antiqua', 'Century Gothic', 'Franklin Gothic Medium', 'Perpetua', 'Rockwell'].filter((f) => set.has(f));
    if (office.length >= 2) software.push({ name: 'Microsoft Office', fonts: office, confidence: 'guess' });
    const adobe = ['Myriad Pro', 'Minion Pro', 'Trajan Pro', 'Adobe Garamond Pro', 'Adobe Caslon Pro', 'Bickham Script Pro'].filter((f) => set.has(f));
    if (adobe.length >= 1) software.push({ name: 'Adobe (CS antiguo)', fonts: adobe, confidence: 'guess' });
    const dev = ['JetBrains Mono', 'Cascadia Code', 'Fira Code', 'Source Code Pro', 'Hack', 'Iosevka', 'Victor Mono'].filter((f) => set.has(f));
    if (dev.length >= 1) software.push({ name: 'Herramientas de desarrollo', fonts: dev, confidence: 'guess' });
    if (set.has('MS Gothic') || set.has('Meiryo')) software.push({ name: 'Paquete de idioma japonés', fonts: [], confidence: 'likely' });
    if (set.has('SimSun') || set.has('Microsoft YaHei')) software.push({ name: 'Paquete de idioma chino', fonts: [], confidence: 'likely' });
    if (set.has('Malgun Gothic')) software.push({ name: 'Paquete de idioma coreano', fonts: [], confidence: 'likely' });
    if (set.has('Nirmala UI')) software.push({ name: 'Paquete de idiomas del sur de Asia', fonts: [], confidence: 'likely' });

    return [
      sig('fonts.list', 'Fuentes detectadas', sorted, {
        display: sorted.slice(0, 10).join(', ') + (sorted.length > 10 ? `, +${sorted.length - 10} más` : ''),
        entropy: 6,
      }),
      sig('fonts.count', 'Fuentes detectadas', sorted.length, { entropy: 2 }),
      sig('fonts.hash', 'Huella de fuentes', hash(sorted.join('|')), { entropy: 4 }),
      sig('fonts.impliedOS', 'SO inferido por fuentes', impliedOS),
      sig('fonts.impliedOSVersion', 'Versión de SO inferida', impliedOSVersion),
      sig('fonts.software', 'Software inferido por fuentes', software, { entropy: 2 }),
    ];
  }

  // ---------------------------------------------------------------------------
  // Geo por IP (única llamada a terceros fuera de WebRTC)
  // ---------------------------------------------------------------------------

  async function probeGeo() {
    try {
      const c = new AbortController();
      const t = setTimeout(() => c.abort(), 6000);
      const res = await fetch('https://ipwho.is/', { signal: c.signal });
      clearTimeout(t);
      if (!res.ok) return;
      const d = await res.json();
      if (d.success === false) return;
      put('geo.ip', 'Dirección IP', d.ip, 24);
      if (d.city) signals['geo.city'] = { id: 'geo.city', label: 'Ciudad (por IP)', value: d.city, entropy: 8 };
      if (d.region) signals['geo.region'] = { id: 'geo.region', label: 'Región (por IP)', value: d.region };
      if (d.country_code) signals['geo.country'] = { id: 'geo.country', label: 'País (por IP)', value: d.country_code, entropy: 4 };
      if (d.timezone?.id) signals['geo.timezone'] = { id: 'geo.timezone', label: 'Zona horaria (por IP)', value: d.timezone.id };
      const org = d.connection?.org;
      const isp = d.connection?.isp;
      const generic = /^(internet service provider|isp|unknown|n\/?a|none|-)$/i;
      const name = org && !generic.test(org.trim()) ? org : isp && !generic.test(isp.trim()) ? isp : null;
      if (name) signals['geo.org'] = { id: 'geo.org', label: 'Operador de red', value: name, entropy: 3 };
      if (d.connection?.asn) signals['geo.asn'] = { id: 'geo.asn', label: 'ASN', value: d.connection.asn };
    } catch { /* sin geo, la sección sigue solo con lo local */ }
  }

  // ---------------------------------------------------------------------------
  // Sondas de tier invasiva (se ejecutan solas, como hace cualquier sitio)
  // ---------------------------------------------------------------------------

  const LOCAL_PORTS = [
    { port: 11434, service: 'Ollama' }, { port: 1234, service: 'LM Studio' },
    { port: 8080, service: 'proxy de desarrollo' }, { port: 3000, service: 'Node/React dev' },
    { port: 5173, service: 'Vite' }, { port: 8000, service: 'Python/Django' },
    { port: 5000, service: 'Flask' }, { port: 3306, service: 'MySQL' },
    { port: 5432, service: 'PostgreSQL' }, { port: 6379, service: 'Redis' },
    { port: 27017, service: 'MongoDB' }, { port: 9200, service: 'Elasticsearch' },
    { port: 2375, service: 'Docker' }, { port: 8888, service: 'Jupyter' },
    { port: 7860, service: 'Gradio/A1111' }, { port: 9000, service: 'Portainer' },
    { port: 4200, service: 'Angular' },
    { port: 5900, service: 'VNC' }, { port: 631, service: 'impresión CUPS' },
    { port: 8096, service: 'Jellyfin' }, { port: 32400, service: 'Plex' },
    { port: 51413, service: 'Transmission' }, { port: 9090, service: 'Prometheus' },
    { port: 3001, service: 'Grafana-ish' },
  ];
  const SCAN_CONCURRENCY = 6;
  const SCAN_FETCH_TIMEOUT = 1200;
  const SCAN_FAST_REJECT = 150;

  async function timeFetch(url) {
    const ctl = new AbortController();
    const onAbort = () => ctl.abort();
    ctrl.signal.addEventListener('abort', onAbort, { once: true });
    const timeoutId = setTimeout(() => ctl.abort(), SCAN_FETCH_TIMEOUT);
    const start = performance.now();
    try {
      await fetch(url, { mode: 'no-cors', signal: ctl.signal, cache: 'no-store' });
      return { ms: performance.now() - start, ok: true, timedOut: false };
    } catch {
      const ms = performance.now() - start;
      return { ms, ok: false, timedOut: ms >= SCAN_FETCH_TIMEOUT - 50 };
    } finally {
      clearTimeout(timeoutId);
      ctrl.signal.removeEventListener('abort', onAbort);
    }
  }

  /** Barrera del escaneo local: un puerto cerrado rechaza casi al instante. */
  async function probeLocalnet() {
    const out = [];
    try {
      const calibrationPort = 49152 + Math.floor(Math.random() * (65535 - 49152));
      const calibration = await timeFetch(`http://127.0.0.1:${calibrationPort}/`);
      const baselineMs = calibration.ms;
      const blocked = calibration.ok || calibration.timedOut || baselineMs > 800;
      if (blocked) {
        out.push(sig('localnet.blocked', 'Escaneo local', true, {
          display: 'el navegador lo rechazó/colgó de forma uniforme; señal inutilizable',
        }));
        return out;
      }
      const threshold = Math.max(baselineMs * 3, baselineMs + 40, SCAN_FAST_REJECT);
      const results = [];
      let next = 0;
      const workers = Array.from({ length: Math.min(SCAN_CONCURRENCY, LOCAL_PORTS.length) }, async () => {
        while (next < LOCAL_PORTS.length) {
          const i = next++;
          if (ctrl.signal.aborted) return;
          const r = await timeFetch(`http://127.0.0.1:${LOCAL_PORTS[i].port}/`);
          results.push({ ...LOCAL_PORTS[i], ...r });
        }
      });
      await Promise.all(workers);
      const open = results
        .filter((r) => r.ok || r.timedOut || r.ms > threshold)
        .map((r) => `${r.port} (${r.service})`);
      out.push(sig('localnet.openPorts', 'Puertos locales abiertos', open, {
        display: open.length ? open.join(', ') : 'no detectados',
        entropy: open.length ? 3 : 0,
      }));
    } catch (err) {
      out.push(sig('localnet.blocked', 'Escaneo local', true, { error: String(err) }));
    }
    return out;
  }

  const STUN_SERVERS = ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'];
  const GATHER_TIMEOUT_MS = 3000;
  const IPv4_RE = /\b(?:\d{1,3}\.){3}\d{1,3}\b/;
  const IPv6_RE = /\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}\b/i;
  const MDNS_RE = /\b[0-9a-f-]+\.local\b/i;

  function isPrivate(ip) {
    return /^10\./.test(ip) || /^192\.168\./.test(ip) ||
      /^172\.(1[6-9]|2\d|3[01])\./.test(ip) || /^169\.254\./.test(ip) || /^fe80:/i.test(ip);
  }

  /** Clásico: ICE filtra la IP real —por LAN y, a veces, la pública— tras una VPN. */
  async function probeWebrtc() {
    const out = [];
    const RTCPC = window.RTCPeerConnection || window.mozRTCPeerConnection || window.webkitRTCPeerConnection;
    if (!RTCPC) {
      out.push(sig('webrtc.localIPs', 'IPs locales filtradas', [], { entropy: 6 }));
      out.push(sig('webrtc.publicIP', 'IP pública filtrada', null, { entropy: 8 }));
      out.push(sig('webrtc.mdns', 'Protección mDNS', false));
      return out;
    }
    let pc = null;
    try {
      pc = new RTCPC({ iceServers: [{ urls: STUN_SERVERS }] });
      pc.createDataChannel('dato');
      const candidateStrings = [];
      const done = new Promise((resolve) => {
        const finish = () => resolve();
        const onAbort = () => finish();
        ctrl.signal.addEventListener('abort', onAbort, { once: true });
        const timer = setTimeout(finish, GATHER_TIMEOUT_MS);
        pc.onicecandidate = (ev) => {
          if (!ev.candidate) { clearTimeout(timer); ctrl.signal.removeEventListener('abort', onAbort); finish(); return; }
          candidateStrings.push(ev.candidate.candidate);
        };
        pc.onicegatheringstatechange = () => {
          if (pc.iceGatheringState === 'complete') { clearTimeout(timer); ctrl.signal.removeEventListener('abort', onAbort); finish(); }
        };
      });
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await done;
      const sdp = pc.localDescription?.sdp ?? '';

      const parse = (str2) => {
        const mdns = str2.match(MDNS_RE);
        if (mdns) return { ip: mdns[0], mdns: true };
        const v4 = str2.match(IPv4_RE);
        const v6 = !v4 ? str2.match(IPv6_RE) : null;
        return { ip: (v4?.[0] ?? v6?.[0] ?? null), mdns: false };
      };

      const all = [...new Set([
        ...candidateStrings,
        ...sdp.split('\n').filter((l) => l.startsWith('a=candidate')),
      ])].map(parse);

      const localIPs = [...new Set(all.filter((p) => p.ip && !p.mdns && isPrivate(p.ip)).map((p) => p.ip))];
      const publicIPs = [...new Set(all.filter((p) => p.ip && !p.mdns && !isPrivate(p.ip)).map((p) => p.ip))];
      const mdnsProtected = all.some((p) => p.mdns);

      out.push(sig('webrtc.localIPs', 'IPs locales filtradas', localIPs, {
        display: localIPs.length ? localIPs.join(', ') : 'ninguna (mDNS o no encontrada)',
        entropy: 6,
      }));
      out.push(sig('webrtc.publicIP', 'IP pública filtrada', publicIPs[0] ?? null, {
        display: publicIPs[0] ?? 'no filtrada',
        entropy: 8,
      }));
      out.push(sig('webrtc.mdns', 'Protección mDNS de IP local', mdnsProtected));

      const fpLines = sdp.split('\n').map((l) => l.trim())
        .filter((l) => l.startsWith('a=extmap:') || l.startsWith('a=rtpmap:') || l.startsWith('a=fmtp:'))
        .sort();
      if (fpLines.length) out.push(sig('webrtc.sdpHash', 'Huella SDP de códecs', hash(fpLines.join('\n')), { entropy: 4 }));
    } catch (err) {
      out.push(sig('webrtc.localIPs', 'IPs locales filtradas', [], { entropy: 6 }));
      out.push(sig('webrtc.publicIP', 'IP pública filtrada', null, { entropy: 8 }));
      out.push(sig('webrtc.mdns', 'Protección mDNS', false));
      out.push(sig('webrtc.error', 'WebRTC', true, { error: String(err) }));
    } finally {
      pc?.close();
    }
    return out;
  }

  const KNOWN_EXTENSIONS = [
    { id: 'nkbihfbeogaeaoehlefnkodbefgpgknn', name: 'MetaMask', resource: 'images/icon-128.png' },
    { id: 'cjpalhdlnbpafiaamejdnhcphjbkeiagm', name: 'uBlock Origin', resource: 'img/icon_128.png' },
    { id: 'ddkjiahejlhfcafbddmgiahcphecmpfh', name: 'uBlock Origin Lite', resource: 'img/icon_128.png' },
    { id: 'gighmmpiobklfepjocnamgkkbiglidom', name: 'AdBlock', resource: 'icons/icon128.png' },
    { id: 'cfhdojbkjhnklbpkdaibdccddilifddb', name: 'Adblock Plus', resource: 'icons/detected-abp/48.png' },
    { id: 'kbfnbcaeplbcioakkpcpgfkobkghlhen', name: 'Grammarly', resource: 'static/_/img/logo-red-48.png' },
    { id: 'hdokiejnpimakedhajhdlcegeplioahd', name: 'LastPass', resource: 'images/icon128.png' },
    { id: 'nngceckbapebfimnlniiiahkandclblb', name: 'Bitwarden', resource: 'images/icon128.png' },
    { id: 'eimadpbcbfnmbkopoojfekhnkhdbieeh', name: 'Dark Reader', resource: 'icons/dr_128x128.png' },
    { id: 'bmnlcjabgnpnenekpadlanbbkooimhnj', name: 'Honey', resource: 'images/icon128.png' },
    { id: 'fmkadmapgofadopljbjfkapdkoienihi', name: 'React DevTools', resource: 'icons/128.png' },
    { id: 'nhdogjmejiglipccpnnnanhbledajbpd', name: 'Vue DevTools', resource: 'icons/128.png' },
    { id: 'bhlhnicpbhignbdhedgjhgdocnmhomnp', name: 'ColorZilla', resource: 'icon128.png' },
    { id: 'liecbddmkiiihnedobmlmillhodjkdmb', name: 'Loom', resource: 'icon128.png' },
  ];

  function probeExtension(url) {
    return new Promise((resolve) => {
      if (ctrl.signal.aborted) return resolve(false);
      const img = new Image();
      let settled = false;
      const timer = setTimeout(() => finish(false), 800);
      const finish = (found) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        img.src = '';
        resolve(found);
      };
      img.onload = () => finish(true);
      img.onerror = () => finish(false);
      try { img.src = url; } catch { finish(false); }
    });
  }

  /** Extensiones (recurso chrome-extension://) y bloqueador de anuncios (cebo). */
  async function probeExtensions() {
    const out = [];
    const detected = [];
    for (const ext of KNOWN_EXTENSIONS) {
      if (ctrl.signal.aborted) break;
      try {
        const found = await probeExtension(
          `chrome-extension://${ext.id}/${ext.resource}`);
        if (found) detected.push(ext.name);
      } catch { /* omitir */ }
    }
    if (detected.length) out.push(sig('ext.detected', 'Extensiones detectadas', detected, {
      display: detected.join(', '), entropy: 3,
    }));

    const bait = document.createElement('div');
    bait.className = 'pub_300x250 text-ad ad-banner adsbox';
    bait.style.cssText = 'position:absolute;left:-9999px;top:-9999px;width:1px;height:1px;';
    bait.innerHTML = '&nbsp;';
    document.body.appendChild(bait);
    const adblock = await new Promise((resolve) => {
      setTimeout(() => {
        const rect = bait.getBoundingClientRect();
        const style = getComputedStyle(bait);
        resolve(
          bait.offsetParent === null || rect.height === 0 ||
          style.display === 'none' || style.visibility === 'hidden',
        );
      }, 120);
    });
    bait.remove();
    if (adblock) out.push(sig('ext.adblock', 'Bloqueador de anuncios', adblock, { entropy: 1 }));

    try {
      if (navigator.brave?.isBrave) {
        const isBrave = await navigator.brave.isBrave();
        if (isBrave) out.push(sig('ext.brave', 'Navegador Brave', true, { entropy: 1 }));
      }
    } catch { /* no exponer */ }

    return out;
  }

  const PERM_NAMES = [
    'geolocation', 'notifications', 'camera', 'microphone', 'clipboard-read',
    'local-fonts', 'window-management', 'persistent-storage', 'display-capture',
    'screen-wake-lock', 'bluetooth', 'background-sync',
  ];
  const CAPABILITY_TESTS = [
    ['hid', () => 'hid' in navigator],
    ['usb', () => 'usb' in navigator],
    ['serial', () => 'serial' in navigator],
    ['bluetooth', () => 'bluetooth' in navigator],
    ['midi', () => 'requestMIDIAccess' in navigator],
    ['gpu', () => 'gpu' in navigator],
    ['Idle Detection', () => 'IdleDetector' in window],
    ['NFC', () => 'NDEFReader' in window],
  ];

  /** Estados de permiso ya otorgados, capacidades y dispositivos emparejados. */
  async function probePermissions() {
    const out = [];
    const granted = [];
    try {
      if (navigator.permissions?.query) {
        await Promise.all(PERM_NAMES.map(async (name) => {
          try {
            const status = await navigator.permissions.query({ name });
            if (status.state === 'granted') granted.push(name);
          } catch { /* nombre no soportado */ }
        }));
      }
    } catch { /* permisos no consultables */ }
    if (granted.length) out.push(sig('perm.granted', 'Permisos ya concedidos a este sitio', granted, {
      display: granted.join(', '), entropy: 2,
    }));

    const caps = CAPABILITY_TESTS.filter(([, test]) => { try { return test(); } catch { return false; } })
      .map(([id]) => id);
    if (caps.length) out.push(sig('perm.capabilities', 'APIs potentes disponibles', caps, {
      display: caps.join(', '), entropy: 2,
    }));

    const paired = [];
    try {
      const hid = navigator.hid?.getDevices;
      if (hid) for (const d of await navigator.hid.getDevices()) if (d.productName) paired.push(`HID: ${d.productName}`);
    } catch { /* sin acceso */ }
    try {
      const usb = navigator.usb?.getDevices;
      if (usb) for (const d of await navigator.usb.getDevices()) paired.push(`USB: ${d.productName || d.manufacturerName || 'dispositivo'}`);
    } catch { /* sin acceso */ }
    if (paired.length) out.push(sig('perm.paired', 'Dispositivos emparejados a este sitio', paired, {
      display: paired.join(' · '), entropy: 4,
    }));

    return out;
  }

  // ---------------------------------------------------------------------------
  // Persistencia estilo evercookie: te reconoceré aunque borres las cookies
  // ---------------------------------------------------------------------------

  const KEY = 'dlab.v1';
  const IDB_NAME = 'dlab';
  const IDB_STORE = 'kv';
  const CACHE_NAME = 'dlab-v1';
  const CACHE_URL = '/__dlab_id';
  const NAME_PREFIX = 'dlab::';

  const backends = {
    localStorage: {
      name: 'localStorage',
      get() { try { return localStorage.getItem(KEY); } catch { return null; } },
      set(v) { try { localStorage.setItem(KEY, v); } catch { /* modo privado */ } },
      del() { try { localStorage.removeItem(KEY); } catch { /* ignorar */ } },
    },
    sessionStorage: {
      name: 'sessionStorage',
      get() { try { return sessionStorage.getItem(KEY); } catch { return null; } },
      set(v) { try { sessionStorage.setItem(KEY, v); } catch { /* ignorar */ } },
      del() { try { sessionStorage.removeItem(KEY); } catch { /* ignorar */ } },
    },
    windowName: {
      name: 'window.name',
      get() { try { return window.name.startsWith(NAME_PREFIX) ? window.name.slice(NAME_PREFIX.length) : null; } catch { return null; } },
      set(v) { try { window.name = NAME_PREFIX + v; } catch { /* ignorar */ } },
      del() { try { if (window.name.startsWith(NAME_PREFIX)) window.name = ''; } catch { /* ignorar */ } },
    },
  };

  function openIDB() {
    return new Promise((resolve, reject) => {
      try {
        const req = indexedDB.open(IDB_NAME, 1);
        req.onupgradeneeded = () => req.result.createObjectStore(IDB_STORE);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      } catch (e) { reject(e); }
    });
  }

  backends.indexedDB = {
    name: 'IndexedDB',
    async get() {
      try {
        const db = await openIDB();
        return await new Promise((resolve) => {
          const r = db.transaction(IDB_STORE, 'readonly').objectStore(IDB_STORE).get(KEY);
          r.onsuccess = () => resolve(r.result ?? null);
          r.onerror = () => resolve(null);
        });
      } catch { return null; }
    },
    async set(v) {
      try { (await openIDB()).transaction(IDB_STORE, 'readwrite').objectStore(IDB_STORE).put(v, KEY); } catch { /* ignorar */ }
    },
    async del() {
      try { (await openIDB()).transaction(IDB_STORE, 'readwrite').objectStore(IDB_STORE).delete(KEY); } catch { /* ignorar */ }
    },
  };

  backends.cacheAPI = {
    name: 'Cache API',
    async get() {
      try {
        const c = await caches.open(CACHE_NAME);
        const res = await c.match(CACHE_URL);
        return res ? await res.text() : null;
      } catch { return null; }
    },
    async set(v) {
      try { (await caches.open(CACHE_NAME)).put(CACHE_URL, new Response(v)); } catch { /* ignorar */ }
    },
    async del() { try { await caches.delete(CACHE_NAME); } catch { /* ignorar */ } },
  };

  const BACKENDS = [backends.localStorage, backends.sessionStorage, backends.indexedDB, backends.cacheAPI, backends.windowName];

  function newId() {
    const b = new Uint8Array(8);
    crypto.getRandomValues(b);
    return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  }

  async function recall() {
    const found = [];
    for (const backend of BACKENDS) found.push([backend, await backend.get()]);
    const survivors = found.filter(([, raw]) => raw).map(([b]) => b.name);
    const restored = found.filter(([, raw]) => !raw).map(([b]) => b.name);
    let record = null;
    for (const [, raw] of found) {
      if (!raw) continue;
      try { const p = JSON.parse(raw); if (p?.id) { record = p; break; } } catch { /* copia corrupta */ }
    }
    const visit = record
      ? { ...record, count: (record.count || 0) + 1, persisted: false, survivors, restored }
      : { id: newId(), first: Date.now(), count: 1, persisted: false, survivors: [], restored: [] };
    const payload = JSON.stringify({ id: visit.id, first: visit.first, count: visit.count });
    for (const b of BACKENDS) await b.set(payload);
    const readBack = [];
    for (const b of BACKENDS) readBack.push(await b.get());
    visit.persisted = readBack.some((r) => !!r);
    return visit;
  }

  async function forget() {
    for (const b of BACKENDS) await b.del();
  }

  // ---------------------------------------------------------------------------
  // Inferencias y narrativa (español, segunda persona)
  // ---------------------------------------------------------------------------

  function osFromUA() {
    const ua = str('ua') || '';
    if (/Windows/.test(ua)) {
      const v = str('osVer') || '';
      if (v.startsWith('13')) return 'Windows 11';
      if (v.startsWith('1.')) return 'Windows 10';
      return 'Windows';
    }
    if (/Android/.test(ua)) return 'Android';
    if (/iPhone|iPad|iPod/.test(ua)) return /iPad/.test(ua) ? 'iPadOS' : 'iOS';
    if (/Macintosh|Mac OS X/.test(ua)) return 'macOS';
    if (/CrOS/.test(ua)) return 'ChromeOS';
    if (/Linux|X11/.test(ua)) return 'Linux';
    return null;
  }

  function browserFromUA() {
    const ua = str('ua') || '';
    if (/Edg\//.test(ua)) return 'Microsoft Edge';
    if (/OPR\/|Opera/.test(ua)) return 'Opera';
    if (/SamsungBrowser/.test(ua)) return 'Samsung Internet';
    if (/Firefox\//.test(ua)) return 'Mozilla Firefox';
    if (/Chrome\//.test(ua)) return 'Google Chrome';
    if (/Safari\//.test(ua)) return 'Safari';
    return null;
  }

  /** Familia de SO (windows/apple/unix) para comparar lecturas independientes. */
  function osFamilyOf(os) {
    if (/Windows/.test(os)) return 'windows';
    if (/Mac|iPadOS|iOS/.test(os)) return 'apple';
    if (/Android|Linux|ubuntu|debian/i.test(os)) return 'unix';
    return null;
  }

  /** Lectura independiente del SO desde las voces de síntesis instaladas. */
  function osFromVoices() {
    const names = signals['voices.hash']?.value;
    if (!Array.isArray(names) || !names.length) return null;
    const joined = names.join(' ').toLowerCase();
    if (/microsoft /.test(joined)) return 'windows';
    if (/siri|com\.apple|samantha|daniel|moira|karen|fiona|alex\b/.test(joined)) return 'apple';
    if (/google |espeak|festival/.test(joined)) return 'unix';
    return null;
  }

  function deviceModelGuess() {
    const ua = str('ua') || '';
    const model = str('model');
    if (model) return /\b(SM-|Pixel|iPhone|iPad)\b/.test(ua) ? model : null;
    if (/iPhone/.test(ua)) return 'un iPhone (el modelo exacto lo esconden)';
    if (/iPad/.test(ua)) return 'un iPad';
    return null;
  }

  function prettyGpu() {
    const raw = str('gpu.renderer');
    if (!raw) return null;
    const r = raw.toLowerCase();
    const apple = raw.match(/Apple\s+(M\d+(?:\s*(?:Pro|Max|Ultra))?)/i);
    if (apple) return `un Apple ${apple[1]}`;
    const nv = raw.match(/(?:GeForce\s+)?(RTX\s*\d{4}\s*(?:Ti)?|GTX\s*\d{3,4}\s*(?:Ti)?)/i);
    if (nv) return `una NVIDIA ${nv[1].replace(/\s+/g, ' ').toUpperCase()}`;
    const amd = raw.match(/(Radeon\s+RX\s*\d{3,4}\s*(?:XT)?)/i);
    if (amd) return `una ${amd[1]}`;
    const intel = raw.match(/(Iris\s+Xe|UHD\s+Graphics\s*\d*|HD\s+Graphics\s*\d*)/i);
    if (/intel/.test(r)) return intel ? `gráficos Intel ${intel[1]}` : null;
    const adreno = raw.match(/Adreno\s*\(TM\)\s*(\d+)/i);
    if (adreno) return `un Qualcomm Adreno ${adreno[1]}`;
    return null;
  }

  function langName(code) {
    const map = {
      en: 'inglés', es: 'español', fr: 'francés', de: 'alemán', it: 'italiano',
      pt: 'portugués', nl: 'neerlandés', ru: 'ruso', ja: 'japonés', ko: 'coreano',
      zh: 'chino', ar: 'árabe', hi: 'hindi', tr: 'turco', pl: 'polaco', sv: 'sueco',
      ca: 'catalán', gl: 'gallego', eu: 'euskera', da: 'danés', fi: 'finés', no: 'noruego',
      cs: 'checo', uk: 'ucraniano', he: 'hebreo', th: 'tailandés', vi: 'vietnamita',
    };
    return map[String(code).toLowerCase()] || null;
  }

  function tzOffsetMinutes(tz) {
    try {
      const d = new Date();
      const utc = new Date(d.toLocaleString('en-US', { timeZone: 'UTC' }));
      const local = new Date(d.toLocaleString('en-US', { timeZone: tz }));
      return Math.round((local.getTime() - utc.getTime()) / 60000);
    } catch { return null; }
  }

  function offsetText(min) {
    const sign = min >= 0 ? '+' : '-';
    const a = Math.abs(min);
    return `UTC${sign}${String(Math.floor(a / 60)).padStart(2, '0')}:${String(a % 60).padStart(2, '0')}`;
  }

  function fmtOneIn(n) {
    return n.toLocaleString('es-ES');
  }

  // ---------------------------------------------------------------------------
  // Renderizado (integrado en el diseño del landing)
  // ---------------------------------------------------------------------------

  function actLabel(text) {
    const p = document.createElement('p');
    p.className = 'act-label';
    p.textContent = text;
    ROOT.append(p);
    return p;
  }

  function addClaim(text, how, confidence = 'likely') {
    const p = document.createElement('p');
    p.className = `claim claim-in c-${confidence}`;
    p.innerHTML = markup(text);
    ROOT.append(p);
    if (how) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'how-toggle';
      btn.textContent = '¿cómo?';
      btn.setAttribute('aria-expanded', 'false');
      const drawer = document.createElement('div');
      drawer.className = 'how';
      drawer.hidden = true;
      drawer.textContent = how;
      btn.addEventListener('click', () => {
        const open = drawer.hidden;
        drawer.hidden = !open;
        btn.setAttribute('aria-expanded', String(open));
      });
      p.append(btn);
      ROOT.append(drawer);
    }
    return p;
  }

  function addLine(text) {
    const p = document.createElement('p');
    p.className = 'claim claim-in';
    p.innerHTML = markup(text);
    ROOT.append(p);
    return p;
  }

  async function revealGeo() {
    const city = str('geo.city');
    const region = str('geo.region');
    const country = str('geo.country');
    const org = str('geo.org');
    const place = [city, region].filter(Boolean).join(', ') || country;
    if (place) {
      addClaim(`Resulta que usted está en o cerca de *${place}*${country && place !== country ? ` (${country})` : ''}.`,
        `Su dirección IP se tradujo con ipwho.is en el propio navegador. Toda web que usted visita conoce su IP en cuanto se conecta y puede hacer esta consulta al instante.\n${esc(display('geo.ip'))}\nZona horaria por IP: ${esc(display('geo.timezone')) ?? 'desconocida'}`,
        'likely');
    }
    if (org) {
      const corporativo = /universidad|institute|google|amazon|microsoft|apple|meta|bank|corp|labs|solutions/i.test(org) && !/vodafone|telekom|orange|movistar|jazztel|masmovil|telefonica|estatico|residencial/i.test(org);
      addClaim(`Su conexión la opera *${esc(org)}*${corporativo ? ', lo que huele a entorno corporativo o institucional' : ''}.`,
        `Cada IP pertenece a un Sistema Autónomo registrado a nombre de una organización; en redes de empresa o universidad, suele ser el nombre del empleador.\nASN: ${signals['geo.asn']?.value ?? '—'}`,
        'likely');
      await sleep(beat());
    }
    const hour = num('env.hour');
    if (typeof hour === 'number') {
      const local = str('env.localTime') || '';
      const m = local.match(/(\d{1,2}):(\d{2})/);
      const clock = m ? `${m[1]}:${m[2]}` : `${hour}:00`;
      if (hour < 5) {
        addClaim(`Son las *${clock}* donde usted está. A esta hora ya no hay vuelta atrás: su equipo me lo acaba de contar.`,
          `Su reloj está ajustado en local y el navegador lo revela sin pedir nada. Ahora mismo lee ${clock}.\nZona horaria: ${esc(display('env.timezone'))}`, 'certain');
      } else if (hour < 8) {
        addClaim(`Son las *${clock}* por ahí: o madrugador, o no ha ido a dormir hoy.`,
          `El navegador informa su hora local exacta (${clock}); no hace falta pedírsela.\nZona horaria: ${esc(display('env.timezone'))}`, 'certain');
      } else {
        addClaim(`Por su parte son las *${clock}*${signals['env.colorScheme']?.value === 'dark' ? ' y navega en modo oscuro' : ''}.`,
          `El navegador informa su hora local (${clock}) y su preferencia de tema. Haría falta menos de lo que cree para adivinar su rutina.`, 'certain');
      }
    }
  }

  async function revealSoftware() {
    const os = osFromUA();
    const browser = browserFromUA();
    if (os) addClaim(`Esto le llega a través de *${esc(os)}*.`,
      `El User-Agent y los client hints (de los que Chrome no pide permiso) dejan claro el sistema operativo.\n\n${esc(display('ua') ?? '')}\nArquitectura: ${esc(display('arch') ?? 'no divulgada')} · Bitness: ${esc(display('bitness') ?? 'no divulgado')}`, 'certain');
    await sleep(beat());
    if (browser) {
      const ua = str('ua') || '';
      const m = browser === 'Microsoft Edge' ? ua.match(/Edg\/(\S+)/)
        : browser === 'Opera' ? ua.match(/OPR\/(\S+)/)
        : browser === 'Mozilla Firefox' ? ua.match(/Firefox\/(\S+)/)
        : browser === 'Samsung Internet' ? ua.match(/SamsungBrowser\/(\S+)/)
        : ua.match(/Chrome\/(\S+)/);
      const ver = m ? ` ${m[1]}` : '';
      addClaim(`Sobre *${esc(browser)}*${ver}${signals['mobile']?.value ? ', en un dispositivo móvil' : ''}.`,
        `El propio navegador firma cada petición con una cadena inequívoca (${esc(display('ua') ?? '')}). Los client hints de alta entropía confirman la versión completa.\n${esc(display('brVer') ?? '')}`, 'certain');
    }
    await sleep(beat());
    const langs = signals.langs?.value;
    if (Array.isArray(langs) && langs.length) {
      const first = langName((langs[0] || '').split('-')[0]);
      addClaim(`Prefiere leer en *${esc(first || langs[0])}*${langs.length > 1 ? ` (entre otros ${langs.length - 1} idiomas configurados)` : ''}.`,
        `navigator.languages listan los idiomas configurados: ${esc(langs.join(', '))}`, 'certain');
    }
  }

  async function revealDevice() {
    const model = deviceModelGuess();
    if (model) addClaim(`Esto lo está leyendo en *${esc(model)}*.`,
      `Los client hints de Chrome revelan el modelo exacto cuando el fabricante lo declara.\n${esc(display('model') ?? '')}`,
      'likely');
    await sleep(beat());
    const gpu = prettyGpu();
    if (gpu) addClaim(`Su gráfica es *${esc(gpu)}*.`,
      `WebGL expone la cadena bruta del renderizador mediante WEBGL_debug_renderer_info, sin pedir permiso.\n\n${esc(display('gpu.renderer') ?? '')}\nFabricante: ${esc(display('gpu.vendor') ?? '')}\nExtensiones: ${esc(display('gpu.extensions') ?? '')}`, 'certain');
    await sleep(beat());

    const bitsList = [];
    const cores = num('hw.cores');
    const hz = num('display.refreshHz');
    const res = signals['display.resolution']?.value;
    const dpr = num('display.pixelRatio') || 1;
    if (cores) bitsList.push(`*${cores}* núcleos a disposición del navegador`);
    if (res) bitsList.push(`pantalla lógica *${res[0]}×${res[1]}*${dpr !== 1 ? ` a ${dpr}×` : ''}`);
    if (hz && hz >= 118) bitsList.push(`refresco *${hz} Hz*`);

    if (bitsList.length >= 2) {
      addClaim(`No está mal su equipo: ${bitsList.join(' y ')}.`,
        `hardwareConcurrency reporta los núcleos lógicos disponibles para la página: en una VM o con límites de CPU pueden ser menos que los físicos. La resolución es la lógica de screen; no la multipliqué por la densidad (el DPR incluye el escalado de la interfaz, así que «lógica × densidad» no da la resolución física real salvo con escala al 100%). El refresco se mide por el timing de los frames.`);
    } else if (bitsList.length === 1) {
      addClaim(`Su equipo tiene ${bitsList[0]}.`);
    }

    const vmsigns = /swiftshader|llvmpipe|vmware|virtualbox|parallels|basic render/i.test(str('gpu.renderer') || '');
    if (vmsigns) {
      addClaim(`Momento. Su GPU es de *renderizado por software*: esto es una *máquina virtual* o un navegador sin aceleración.`,
        `El renderizador WebGL (${esc(display('gpu.renderer') ?? '')}) corresponde a adaptadores virtuales o rasterizadores software; el hardware real no se anuncia así.`);
    }

    if (signals['display.multiMonitor']?.value) {
      addClaim(`Y tiene *más de una pantalla* conectada.`,
        `screen.isExtended devuelve true cuando hay un segundo monitor, sin permiso y sin decir qué se está viendo en él.`, 'certain');
    }
    const cams = num('hw.cameras');
    const mics = num('hw.mics');
    const labels = signals['hw.labels']?.value === true;
    const periph = [];
    if (cams) periph.push('una cámara');
    if (mics) periph.push('un micrófono');
    if (periph.length) {
      addClaim(`Tiene ${periph.join(' y ')} conectado${periph.length > 1 ? 's' : ''}${labels ? ', y el navegador llega a ver sus *nombres*' : ''}.`,
        `enumerateDevices() revela qué tipos de dispositivo hay sin permiso; los nombres concretos solo aparecen si algún día concedió acceso de dispositivo a esta web u otra.`);
    }
    const netKind = signals['hw.netKind']?.value;
    if (netKind) {
      addClaim(`Navega por *${esc(netKind)}*${typeof num('hw.downlink') === 'number' ? ` (el navegador estima ~${num('hw.downlink')} Mbps)` : ''}.`,
        `navigator.connection.type informa del medio físico (ethernet, wifi, cellular) sin permiso.\nRTT: ${num('hw.rtt') != null ? `${num('hw.rtt')} ms` : 'no divulgado'}`);
    }
  }

  async function revealContradictions() {
    const ipTz = str('geo.timezone');
    const browserTz = str('env.timezone');
    const ipOff = ipTz ? tzOffsetMinutes(ipTz) : null;
    const browserOff = browserTz
      ? tzOffsetMinutes(browserTz)
      : (typeof signals['env.tzOffset']?.value === 'number' ? signals['env.tzOffset'].value : null);
    const mismatchTz = ipOff != null && browserOff != null && Math.abs(ipOff - browserOff) > 20;

    // VPN por contradicción IP vs reloj.
    if (ipTz && browserTz && mismatchTz) {
      const ipCity = ipTz.split('/').pop()?.replace(/_/g, ' ');
      const realCity = browserTz.split('/').pop()?.replace(/_/g, ' ');
      addClaim(`Su IP le sitúa en *${esc(ipCity)}* (${offsetText(ipOff)}), pero el reloj del sistema piensa que está en *${esc(realCity)}* (${offsetText(browserOff)}). Uno de los dos miente, y no es el reloj: es un *VPN*.`,
        `La red ve su salida VPN (${ipTz}). Pero la zona horaria de su sistema viaja con usted por el túnel y el VPN no puede reescribirla. Los desfases difieren >20 min, así que hay túnel.`,
        'likely');
    }

    // Idioma vs país.
    const langs = signals.langs?.value;
    const country = str('geo.country');
    if (Array.isArray(langs) && langs.length && country) {
      const map = {
        US: ['en'], GB: ['en'], AU: ['en'], CA: ['en', 'fr'], IE: ['en'], NZ: ['en'],
        DE: ['de'], AT: ['de'], FR: ['fr'], ES: ['es'], MX: ['es'], AR: ['es'],
        IT: ['it'], NL: ['nl'], BR: ['pt'], PT: ['pt'], JP: ['ja'], KR: ['ko'],
        RU: ['ru'], SE: ['sv'], NO: ['no', 'nb'], DK: ['da'], FI: ['fi'], PL: ['pl'],
      };
      const allowed = map[country];
      const l = langs[0].split('-')[0].toLowerCase();
      const localName = langName(l) || l;
      const matches = allowed && langs.some((x) => allowed.includes(x.split('-')[0].toLowerCase()));
      if (allowed && !matches) {
        addClaim(`Su navegador habla *${esc(localName)}*, pero su IP está en *${esc(country)}*${mismatchTz ? ', y eso ya sabemos qué es' : ', donde no es el idioma local'}.${mismatchTz ? '' : ` Posibilidades: multilingüe, de viaje… o *VPN*.`}`,
          `Su idioma configurado (${esc(langs.join(', '))}) no coincide con el país de su IP (${country}${mismatchTz ? ') y además su reloj discrepa → túnel casi seguro' : ')'}.`,
          mismatchTz ? 'likely' : 'guess');
      }
    }

    // Suplantación de User-Agent por contradicción con fuentes. Solo acusamos
    // si una segunda lectura independiente (las voces de síntesis) lo corrobora:
    // las fuentes solas son demasiado ruidosas.
    const uaOS = osFromUA();
    const fontOS = signals['fonts.impliedOS']?.value;
    if (uaOS && fontOS && fontOS !== 'unknown') {
      const famUA = osFamilyOf(uaOS);
      const famFont = osFamilyOf(fontOS);
      const voiceFam = osFromVoices();
      const corroborated = voiceFam != null && voiceFam !== famUA;
      if (famUA && famFont && famUA !== famFont && corroborated) {
        addClaim(`Su User-Agent dice *${esc(uaOS)}*, pero sus fuentes instaladas son de *${esc(fontOS)}*. Uno de los dos se inventa la identidad, y no son las fuentes.`,
          `El User-Agent es trivial de falsificar; ciertas fuentes solo las traen ciertos sistemas. Las suyas (${esc(display('fonts.impliedOS') ?? '')}) delatan a ${fontOS}, no a ${uaOS}. Lo confirman también sus voces de síntesis, de ${voiceFam}.\nVersión implícita: ${esc(signals['fonts.impliedOSVersion']?.value ?? 'indeterminada')}`,
          'likely');
      }
    }

    // Navegador automatizado o VM.
    if (signals['webdriver']?.value) {
      addClaim(`Y ya que hablamos de mentiras: navigator.webdriver dice *true*. Esto no es una persona, es un *navegador automatizado*.`,
        `Los navegadores sin cabeza y las herramientas de automatización dejan esta bandera activa. ${esc(display('ua') ?? '')}`, 'certain');
    }
    if (signals['ext.brave']?.value === true) {
      addClaim(`Usa *Brave*, que no se lo ha dicho a nadie: el propio navegador se delata.`,
        `Brave instala una API oculta (navigator.brave) y comportamientos de antifingerprinting tan característicos que acaban siendo una huella.`, 'certain');
    }
  }

  async function revealInstalled() {
    const software = signals['fonts.software']?.value;
    const list = Array.isArray(software) ? software.map((s) => s.name) : [];
    if (list.length) {
      addClaim(`Por sus fuentes deduzco que tiene instalado: *${esc(list.join(' · '))}*.`,
        `Ciertas fuentes solo llegan con ciertos programas (LaTeX, Office, Adobe, IDEs, paquetes de idioma). Su lista detectada (${esc(display('fonts.list') ?? '')}) delata la instalación. Las inferencias de software son conjeturas: una fuente también puede llegar por otro camino.`,
        'guess');
    }
    const count = num('fonts.count');
    if (typeof count === 'number' && count > 0) {
      addClaim(`Su sistema expuso *${count}* fuentes detectables en la prueba.`,
        `Medimos los anchos de texto en un canvas con tipografías candidatas; si la muestra cambia bajo las tres familias genéricas, la fuente existe. Detección por medida, sin que el navegador lo confiese (${esc(display('fonts.list') ?? '')}).`);
    }
    const voiceLangs = signals['voices.langs']?.value;
    if (Array.isArray(voiceLangs) && voiceLangs.length) {
      addClaim(`Tiene ${signals['voices.count']?.value ?? ''} voces de síntesis instaladas (${esc(voiceLangs.slice(0, 3).join(', '))}${voiceLangs.length > 3 ? '…' : ''}).`,
        `speechSynthesis enumera las voces del SO sin permiso; el conjunto es una señal fiable de idioma y plataforma.\n${esc(display('voices.langs') ?? '')}`);
    }
  }

  async function revealInvasive() {
    const localIPs = signals['webrtc.localIPs']?.value;
    const local = Array.isArray(localIPs) && localIPs.length ? localIPs.join(', ') : null;
    const pub = str('webrtc.publicIP');
    if (local) {
      const mdnsGuard = signals['webrtc.mdns']?.value === true;
      addClaim(`Vía WebRTC he filtrado su IP *local* de red: *${esc(local)}*${pub ? `, y la *pública* *${esc(pub)}* —${(str('geo.ip') && pub === str('geo.ip')) ? 'clavada, la misma que el túnel' : 'asomándose aun con ese túnel'}` : ''}.`,
        `RTCPeerConnection con un servidor STUN de Google negocia candidatos ICE por UDP; buena parte de los clientes VPN no interceptan esa ruta y la IP real se cuela en el SDP. Por eso se avisa: la IP sí sale hacia Google STUN.\n${mdnsGuard ? 'Protección mDNS activa para la IP local' : 'mDNS no activo'}`,
        mdnsGuard ? 'guess' : 'likely');
    } else if (!local && signals['webrtc.mdns']?.value === true) {
      addClaim(`Su IP local está *protegida con mDNS*: WebRTC solo ha expuesto un nombre cifrado, no la dirección. Raro en la web, y bien por ello.`,
        `Chrome sustituye la IP local por un nombre .local generado cuando la protección de IP local está activa. El intento de ocultarse es ya una señal.`);
    }
    await sleep(beat());

    if (signals['localnet.openPorts']?.value && signals['localnet.openPorts'].value.length) {
      addClaim(`En su propio equipo hay servicios *escuchando* que se dejan ver: *${esc(display('localnet.openPorts'))}*.`,
        `Un puerto cerrado rechaza la conexión casi al instante; uno abierto la acepta o la mantiene colgada. Basándonos en el timing de unas fetch de prueba contra 127.0.0.1 distinguimos ambos casos. Es heurístico y puede tener falsos positivos.`,
        'guess');
    }

    const exts = signals['ext.detected']?.value;
    if (Array.isArray(exts) && exts.length) {
      addClaim(`Tiene instaladas extensiones que se delatan solas: *${esc(exts.join(' · '))}*.`,
        `Las extensiones cuelgan recursos web_accessible_resources bajo chrome-extension://ID/…; una <img> apuntando ahí carga solo si la extensión existe. No leemos bytes, solo si responde.`,
        'certain');
    }
    if (signals['ext.adblock']?.value === true) {
      addClaim(`Y lleva un *bloqueador de anuncios* activo.`,
        `Plantamos un elemento con las clases que las listas de filtros ocultan; si desaparece, hay un bloqueador actuando.`);
    }

    const caps = signals['perm.capabilities']?.value;
    if (Array.isArray(caps) && caps.length) {
      addClaim(`Su navegador expone APIs *potentes* y sin permiso previo: *${esc(display('perm.capabilities'))}*. Son llaves que lo acercan a su hardware.`,
        `${caps.length} capacidades sensibles disponibles. Varias de ellas pueden leerse o enumerarse sin diálogo: lea la fila en la tabla.`,
        'certain');
    }
    const granted = signals['perm.granted']?.value;
    if (Array.isArray(granted) && granted.length) {
      addClaim(`En algún momento ha concedido a esta web (u otra en su navegador) acceso a *${esc(granted.join(' · '))}*.`,
        `navigator.permissions.query() informa del estado 'granted' sin mostrar ningún diálogo. Los sitios pueden leer este historial de concesiones en silencio.`,
        'certain');
    }
    const paired = signals['perm.paired']?.value;
    if (Array.isArray(paired) && paired.length) {
      addClaim(`Y tiene dispositivos *emparejados* accesibles: ${esc(display('perm.paired'))}.`,
        `getDevices() de WebHID/WebUSB enumera lo que ya vinculó a este origen, sin aviso nuevo.`);
    }
  }

  async function revealVisit(visit) {
    if (!visit.persisted) {
      addClaim(`He intentado etiquetarle para reconocerle en su próxima visita, y su navegador *ha tirado la etiqueta*: todos mis escondrijos volvieron vacíos. Para mí será una persona nueva cada vez. Eso es su configuración funcionando, y es más raro de lo que piensa.`,
        `Escribí una marca aleatoria en localStorage, IndexedDB, Cache API y window.name y volví a leerlos: nada sobrevivió. Bloqueo de tracking estricto, ventana privada o «borrar al cerrar».\n(Nota: si además aleatoriza canvas y audio, la huella cambia en cada visita.)`,
        'certain');
      return;
    }
    const wipeText = () => {
      const restored = visit.restored.filter((n) => n !== 'window.name');
      const survivors = visit.survivors;
      const parts = [];
      if (restored.length) parts.push(`${restored.length} de mis escondrijos estaban vacíos (${esc(restored.join(', '))})`);
      if (survivors.length) parts.push(`sobrevivieron ${esc(survivors.join(', '))}`);
      return parts.join('; ') || 'todos mis almacenes quedaron intactos';
    };

    if (visit.count <= 1) {
      addClaim(`Primera vez por aquí. Ya le he etiquetado: *vuelva*, y lo demuestro. Sin cookies, y sin que el servidor guarde nada.`,
        `Escribí una marca aleatoria en localStorage, sessionStorage, IndexedDB, Cache API y window.name a la vez, al estilo evercookie. Si pulsa «Olvídame», se destruye de verdad.\nNunca usamos cookies: el servidor no guardó nada.`,
        'certain');
    } else {
      const daysAgo = Math.max(0, Math.round((Date.now() - visit.first) / 86400000));
      const when = daysAgo === 0 ? 'hoy mismo' : daysAgo === 1 ? 'ayer' : `hace ${daysAgo} días`;
      const lede = visit.count >= 4
        ? `¿Le gusta mucho esta web, no? Es la visita número *${visit.count}*.`
        : `Ya nos conocemos: vino por primera vez *${when}*. Visita número *${visit.count}*.`;
      addClaim(`${lede} ${visit.count > 1 && visit.survivors.length ? `Y noto que ha borrado parte de lo que guardé (${wipeText()}); lo restauré desde lo que quedaba.` : ''}`,
        `La marca aleatoria reside en varios almacenes a la vez; borrar cookies (que no usamos) no la toca. Para olvidarle de verdad hay que limpiar todos a la vez… o pulsar «Olvídame» abajo, que sí funciona.\nSobrevivientes: ${esc(visit.survivors.join(', ') || 'ninguno')} · Restaurados: ${esc(visit.restored.join(', ') || 'ninguno')}`,
        'certain');
    }
  }

  function funnelRows() {
    const os = osFromUA() ? ((ua) => (/Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /Macintosh|Mac OS X|iPhone|iPad/.test(ua) ? (ua.match(/iPhone|iPad/) ? 'iOS' : 'macOS') : /Linux/.test(ua) ? 'Linux' : 'otro'))(str('ua') || '') : null;
    const osPrev = { Windows: 0.30, Android: 0.40, macOS: 0.18, iOS: 0.07, Linux: 0.04 };
    const br = browserFromUA();
    const brPrev = {
      'Google Chrome': 0.64, 'Microsoft Edge': 0.05, Safari: 0.18,
      'Mozilla Firefox': 0.03, Opera: 0.02, 'Samsung Internet': 0.03,
    };
    const res = signals['display.resolution']?.value;
    const resPrev = {
      '1920,1080': 0.20, '1366,768': 0.06, '1536,864': 0.05, '2560,1440': 0.04,
      '1440,900': 0.03, '3840,2160': 0.02, '1280,720': 0.02,
    };
    const rows = [];
    if (os) rows.push({ label: 'Sistema', value: os, pct: osPrev[os] ?? 0.02 });
    if (br) rows.push({ label: 'Navegador', value: br, pct: brPrev[br] ?? 0.02 });
    if (Array.isArray(signals.langs?.value) && signals.langs.value.length) {
      const l = langName(signals.langs.value[0].split('-')[0]);
      const prev = { inglés: 0.35, español: 0.08, francés: 0.04, alemán: 0.04, chino: 0.07, portugués: 0.05, japonés: 0.03 };
      rows.push({ label: 'Idioma', value: l || signals.langs.value[0], pct: prev[l] ?? 0.01 });
    }
    if (res) {
      const key = `${res[0]},${res[1]}`;
      rows.push({ label: 'Pantalla', value: `${res[0]} × ${res[1]}`, pct: resPrev[key] ?? 0.01 });
    }
    const tz = str('env.timezone');
    const tzPrev = { 'Europe/Madrid': 0.012, 'Europe/London': 0.03, 'Europe/Paris': 0.03, 'Europe/Berlin': 0.03, 'America/New_York': 0.06 };
    if (tz) rows.push({ label: 'Zona horaria', value: tz, pct: tzPrev[tz] ?? 0.008 });

    let product = 1;
    return rows.map((r) => {
      product *= Math.max(r.pct, 0.0001);
      return { ...r, cumulative: Math.round(1 / product) };
    });
  }

  function renderFunnel() {
    const rows = funnelRows();
    if (rows.length < 2) return;
    actLabel('Cómo de raro es');
    addLine('Cada dato por su cuenta es común. Mire lo rápido que se multiplican.');
    const host = document.createElement('div');
    ROOT.append(host);
    for (const r of rows) {
      const pctTxt = r.pct >= 0.01 ? `${Math.round(r.pct * 100)}%` : `${(r.pct * 100).toFixed(1)}%`;
      const line = document.createElement('div');
      line.className = 'funnel-row';
      line.innerHTML =
        `<div class="funnel-head"><span class="funnel-label">${esc(r.label)}</span><span class="funnel-val">${esc(r.value)}</span></div>` +
        `<div class="funnel-bar"><span style="width:${Math.max(2, Math.min(100, r.pct * 100))}%"></span></div>` +
        `<div class="funnel-meta"><span>${pctTxt} de la gente</span><span class="funnel-cum">1 entre ${r.cumulative.toLocaleString('es-ES')}</span></div>`;
      host.append(line);
    }
  }

  async function finalize(visit) {
    actLabel('El recibo');
    const fp = deviceFingerprint();
    const bits = totalEntropy();
    const oneIn = Math.round(Math.pow(2, bits));
    addLine(`Con todo junto, más o menos *1 de cada ${fmtOneIn(oneIn)}* navegadores se parece al suyo. Y ninguna cookie intervino.`);
    const pV = document.createElement('p');
    pV.className = 'verdict';
    pV.textContent = 'La huella de este dispositivo, esta visita:';
    ROOT.append(pV);
    const pF = document.createElement('p');
    pF.className = 'fingerprint';
    pF.textContent = fp;
    ROOT.append(pF);
    const pBits = document.createElement('p');
    pBits.className = 'bits';
    pBits.textContent = `${bits.toFixed(1)} bits de entropía · ${Object.keys(signals).length} señales leídas`;
    ROOT.append(pBits);

    const rawWrap = document.createElement('div');
    rawWrap.className = 'raw-wrap';
    rawWrap.hidden = true;
    const rows = Object.values(signals)
      .filter((s) => !s.error)
      .map((s) => ({ label: s.label, value: display(s.id) ?? '' }));
    const t = document.createElement('table');
    t.className = 'raw';
    t.innerHTML = `<tbody>${rows.map((r) => `<tr><td>${esc(r.label)}</td><td>${esc(r.value || '—')}</td></tr>`).join('')}</tbody>`;
    rawWrap.append(t);
    ROOT.append(rawWrap);

    const rawBtn = document.createElement('button');
    rawBtn.type = 'button';
    rawBtn.className = 'mini-btn raw-toggle';
    rawBtn.textContent = 'Ver los datos en bruto';
    rawBtn.addEventListener('click', () => {
      rawWrap.hidden = !rawWrap.hidden;
      rawBtn.textContent = rawWrap.hidden ? 'Ver los datos en bruto' : 'Ocultar los datos en bruto';
    });
    ROOT.append(rawBtn);

    const forgetBtn = document.createElement('button');
    forgetBtn.type = 'button';
    forgetBtn.className = 'mini-btn primary';
    forgetBtn.textContent = 'Olvídame';
    forgetBtn.addEventListener('click', async () => {
      await forget();
      forgetBtn.textContent = 'Olvidado: recargue para confirmarlo';
      forgetBtn.disabled = true;
    });
    ROOT.append(forgetBtn);

    const note = document.createElement('p');
    note.className = 'dossier-note';
    note.innerHTML =
      `Nada de esto viajó a un servidor D-Lab: se calculó en su navegador o se leyó de la propia conexión. ` +
      `Las únicas excepciones, dichas en voz alta, son la geolocalización por IP (ipwho.is) y los ` +
      `servidores STUN de Google usados por WebRTC, a los que su IP llega. Y recuerde: esta sección se ` +
      `esforzó en <em>enseñárselo</em>. El sitio que abra a continuación puede hacer todo esto también, ` +
      `y no se lo va a contar. <br>Adaptado del proyecto open-source ` +
      `<a href="https://github.com/Kuberwastaken/cookie" target="_blank" rel="noopener">cookie</a> de Kuber Mehta.`;
    ROOT.append(note);
  }

  // ---------------------------------------------------------------------------
  // Orquestación: recopilación en segundo plano + dossier a demanda.
  // ---------------------------------------------------------------------------

  const introHow =
    `Leemos deliberadamente: plataforma, pantalla, renderizado, fuentes, hora y zona horaria, ` +
    `impresiones de canvas y audio, códecs, voces. Todo son lecturas que el navegador entrega a ` +
    `cualquier web sin pedir permiso. Nada se guardó en el servidor de esta página.`;

  /** Recopila toda la señal en segundo plano; resuelve con el registro de visitas. */
  async function collect() {
    const geoP = probeGeo();
    const fastP = Promise.all([probePlatform(), probeDisplay(), probeHardware(), probeEnvironment(), probeGpu()]);
    const slowP = Promise.all([probeCodecs(), probeVoices(), probeCanvas(), probeAudio(), probeFonts()]);
    const visitP = recall();
    const visitGuarded = Promise.race([
      visitP,
      new Promise((resolve) => setTimeout(() => resolve({ id: null, first: Date.now(), count: 1, persisted: true, survivors: [], restored: [] }), 2500)),
    ]);
    await geoP;
    for (const batch of await fastP) for (const s of batch) signals[s.id] = s;
    for (const batch of await slowP) for (const s of batch) signals[s.id] = s;
    const invasive = await Promise.race([
      Promise.all([probeLocalnet(), probeWebrtc(), probeExtensions(), probePermissions()]),
      new Promise((resolve) => setTimeout(() => resolve([]), 12000)),
    ]);
    for (const batch of invasive) for (const s of batch) signals[s.id] = s;
    return visitGuarded;
  }

  /** Pinta el dossier completo de una sola tanda. Los cajones «¿cómo?» y la tabla en bruto nacen plegados. */
  async function renderDossier(visit) {
    instant = true;
    try {
      addClaim('He estado leyendo su navegador desde que tocó esta página. Esto es lo que ha contado — sin pedir permiso, y sin que yo lo guarde.', introHow, 'certain');
      actLabel('Dónde está'); await revealGeo();
      actLabel('Qué usa'); await revealSoftware();
      actLabel('Con qué lo lee'); await revealDevice();
      actLabel('Cosas que no cuadran'); await revealContradictions();
      actLabel('Qué tiene instalado'); await revealInstalled();
      actLabel('Lo que su máquina suelta'); await revealInvasive();
      actLabel('Nos hemos visto'); await revealVisit(visit);
      renderFunnel();
      await finalize(visit);
    } finally {
      instant = false;
    }
  }

  const showAllBtn = document.getElementById('mostrar-mas-info');
  const BTN_SHOW = 'Mostrar TU info';
  const BTN_HIDE = 'Ocultar la información';
  let shown = false;
  let rendered = false;
  let cachedVisit = null;
  const readyP = collect().catch(() => null);

  if (showAllBtn) {
    showAllBtn.addEventListener('click', async () => {
      if (shown) {
        shown = false;
        ROOT.replaceChildren();
        showAllBtn.textContent = BTN_SHOW;
        showAllBtn.setAttribute('aria-expanded', 'false');
        return;
      }
      shown = true;
      if (!rendered) {
        showAllBtn.disabled = true;
        showAllBtn.textContent = 'Descifrando…';
        try {
          cachedVisit = await readyP;
          await renderDossier(cachedVisit || { id: null, first: Date.now(), count: 1, persisted: true, survivors: [], restored: [] });
          rendered = true;
        } catch (err) {
          if (ROOT) ROOT.innerHTML = `<p class="claim">Algo falló mientras le leía. Irónicamente, ese es el resultado privado. <span class="how">${esc(String(err))}</span></p>`;
          shown = false;
          showAllBtn.disabled = false;
          showAllBtn.textContent = BTN_SHOW;
          showAllBtn.setAttribute('aria-expanded', 'false');
          return;
        }
      } else {
        await renderDossier(cachedVisit || { id: null, first: Date.now(), count: 1, persisted: true, survivors: [], restored: [] });
      }
      showAllBtn.disabled = false;
      showAllBtn.textContent = BTN_HIDE;
      showAllBtn.setAttribute('aria-expanded', 'true');
    });
  }
})();