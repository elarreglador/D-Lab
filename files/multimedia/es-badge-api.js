/* es-badge-api — backend de disponibilidad de idiomas para Jellyseerr.
 *
 * Endpoint: GET /search?mediaType=movie|tv&tmdbId=<id>&q=<título>
 * Devuelve JSON con las insignias disponibles ANTES de la descarga:
 *   {"ES":bool,"LAT":bool,"SUB":bool,"EN":bool,"total":n,"cached":bool}
 *
 * Fuente de verdad: releases reales en los indexadores directos de Prowlarr
 * (Torrent9, LimeTorrents, Torrent Downloads; excluye 1337x por lentitud via
 * FlareSolverr). Los indexadores públicos no soportan búsqueda por tmdbId,
 * así que se busca por keyword y se filtran los resultados por coincidencia
 * de título. Clasificación heurística por nombre de release (las mismas
 * señales que la política de Custom Formats de Sonarr/Radarr).
 *
 * Caché: en memoria + persistida en /cache/cache.json (emptyDir), TTL 24 h,
 * clave (mediaType, tmdbId). Una sola búsqueda Prowlarr concurrente.
 */
'use strict';

const http = require('http');

const PORT = Number(process.env.PORT || 8080);
const PROWLARR_URL = process.env.PROWLARR_URL || 'http://prowlarr:9696';
const APIKEY = process.env.PROWLARR_APIKEY || '';
const INDEXER_IDS = (process.env.INDEXER_IDS || '6,7,8').split(',');
const CACHE_FILE = process.env.CACHE_FILE || '/cache/cache.json';
const CACHE_TTL_MS = Number(process.env.CACHE_TTL_MS || 24 * 3600 * 1000);
const SEARCH_TIMEOUT_MS = Number(process.env.SEARCH_TIMEOUT_MS || 30000);

// --- Clasificador ----------------------------------------------------------

const RE_ES = /castellano|espa[ñn]ol|spanish|\bdual\b|\bmulti\b|\bspa\b|spa-?eng/i;
const RE_LAT = /latino|es-419|es_419|esp[-_.]?lat|latam/i;
const RE_SUB = /\bvose\b|\bvos\b|(subtitle|subtitulad|subbed|subs|subtitulo)([\s\-_.]*)(spanish|espa[ñn]ol|castellano)?/i;
const RE_EN = /english|ingles|ingl[ée]s|\beng\b|\bdual\b|\bmulti\b|spa-?eng/i;

function classifyTitle(title) {
  const flags = { ES: false, LAT: false, SUB: false, EN: false };
  if (!title) return flags;
  const t = String(title);
  if (RE_ES.test(t)) flags.ES = true;
  if (RE_LAT.test(t)) flags.LAT = true;
  if (RE_SUB.test(t)) flags.SUB = true;
  if (RE_EN.test(t)) flags.EN = true;
  return flags;
}

// --- Filtrado por coincidencia de título -----------------------------------

const STOPWORDS = new Set([
  'the', 'and', 'of', 'for', 'with', 'from', 'into', 'this', 'that', 'you',
  'a', 'an', 'de', 'la', 'el', 'los', 'las', 'del', 'en', 'y', 'the', 'da',
]);

function tokens(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/[^a-z0-9áéíóúñü]+/g, ' ')
    .split(' ')
    .filter((w) => w.length >= 3 && !STOPWORDS.has(w));
}

// Requiere que el resultado comparta suficientes tokens significativos con el título buscado.
function matchesTitle(resultTitle, queryTitle) {
  const q = tokens(queryTitle);
  if (q.length === 0) return true;
  const r = new Set(tokens(resultTitle));
  const shared = q.filter((w) => r.has(w)).length;
  const needed = Math.min(q.length, Math.max(2, Math.ceil(q.length / 2)));
  return shared >= needed;
}

// --- Caché ------------------------------------------------------------------

let cache = new Map(); // key -> {flags, ts}
let writeQueued = false;

function loadCache() {
  try {
    const data = JSON.parse(require('fs').readFileSync(CACHE_FILE, 'utf8'));
    for (const [k, v] of Object.entries(data || {})) {
      if (v && v.ts && Date.now() - v.ts < CACHE_TTL_MS) cache.set(k, v);
    }
  } catch {
    /* primera vez: no hay fichero */
  }
}

function saveCache() {
  if (writeQueued) return;
  writeQueued = true;
  setImmediate(() => {
    writeQueued = false;
    const fs = require('fs');
    try {
      const tmp = CACHE_FILE + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(Object.fromEntries(cache)));
      fs.renameSync(tmp, CACHE_FILE);
    } catch {
      /* caché efímera: si no se puede escribir, se pierde al reiniciar */
    }
  });
}

function cacheGet(key) {
  const v = cache.get(key);
  if (v && Date.now() - v.ts < CACHE_TTL_MS) return v.flags;
  return null;
}

function cacheSet(key, flags) {
  cache.set(key, { flags, ts: Date.now() });
  saveCache();
}

// --- Búsqueda Prowlarr (una concurrente) ------------------------------------

let searchChain = Promise.resolve();

function withSearchLock(fn) {
  const run = searchChain.then(fn, fn);
  searchChain = run.then(() => undefined, () => undefined);
  return run;
}

async function prowlarrSearch(query, mediaType) {
  const type = mediaType === 'movie' ? 'movie' : 'tvsearch';
  const params = new URLSearchParams();
  params.set('query', query);
  params.set('type', type);
  for (const id of INDEXER_IDS) params.append('indexerIds', id);
  const url = `${PROWLARR_URL}/api/v1/search?${params.toString()}`;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), SEARCH_TIMEOUT_MS);
  try {
    const resp = await fetch(url, {
      headers: { 'X-Api-Key': APIKEY },
      signal: ctl.signal,
    });
    if (!resp.ok) throw new Error('Prowlarr HTTP ' + resp.status);
    const data = await resp.json();
    if (!Array.isArray(data)) throw new Error('Respuesta Prowlarr inesperada');
    return data;
  } finally {
    clearTimeout(timer);
  }
}

async function computeFlags(key, mediaType, q) {
  const cached = cacheGet(key);
  if (cached) return { flags: cached, cached: true };

  const flags = { ES: false, LAT: false, SUB: false, EN: false };
  let total = 0;
  try {
    const results = await withSearchLock(() => prowlarrSearch(q, mediaType));
    for (const r of results) {
      if (!matchesTitle(r.title || '', q)) continue;
      total++;
      const f = classifyTitle(r.title);
      if (f.ES) flags.ES = true;
      if (f.LAT) flags.LAT = true;
      if (f.SUB) flags.SUB = true;
      if (f.EN) flags.EN = true;
    }
  } catch {
    /* sin conexión con Prowlarr: devolver todo false */
  }
  const out = Object.assign({}, flags, { total });
  cacheSet(key, out);
  return { flags: out, cached: false };
}

// --- Servidor HTTP ----------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const respond = (code, obj) => {
    const body = JSON.stringify(obj);
    res.writeHead(code, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    });
    res.end(body);
  };

  try {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname;

    if (req.method === 'GET' && path === '/health') {
      return respond(200, { ok: true });
    }

    if (req.method === 'GET' && path === '/search') {
      const mediaType = url.searchParams.get('mediaType');
      const tmdbId = url.searchParams.get('tmdbId');
      const q = (url.searchParams.get('q') || '').trim();
      if ((mediaType !== 'movie' && mediaType !== 'tv') || !tmdbId || !q) {
        return respond(400, { error: 'mediaType (movie|tv), tmdbId y q son obligatorios' });
      }
      const key = `${mediaType}:${tmdbId}`;
      const { flags, cached } = await computeFlags(key, mediaType, q);
      return respond(200, Object.assign({}, flags, { cached }));
    }

    return respond(404, { error: 'no encontrado' });
  } catch (e) {
    return respond(500, { error: 'internal error: ' + e.message });
  }
});

loadCache();
server.listen(PORT, '0.0.0.0', () => {
  console.log(`es-badge-api escuchando en :${PORT} (indexers ${INDEXER_IDS.join(',')})`);
});