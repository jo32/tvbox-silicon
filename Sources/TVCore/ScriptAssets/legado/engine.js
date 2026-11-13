// Legado book sources (github.com/LegadoTeam/legado, GPL-3.0) on QuickJS, for NovelRuntime.swift.
// A port of Legado's rule engine: AnalyzeRule (rule modes, rule chains, {{}} templates, @put/@get, ##
// replacements), AnalyzeByJSoup, AnalyzeByXPath (xpath.js), AnalyzeByJSonPath (jsonpath-plus from the
// cheerio bundle), AnalyzeByRegex, AnalyzeUrl, and the WebBook flow (BookList, BookInfo, BookChapterList,
// BookContent). Like Legado's Rhino scripts everything is synchronous: HTTP goes through __host('http').
// Runs after the TVBox prelude (URL, TextEncoder, Buffer, atob/btoa, local storage through __host).
import * as cheerio from 'assets://js/lib/cheerio.min.js';
import * as XPath from 'assets://legado/xpath.js';

const host = globalThis.__host;
const $E = cheerio.load('');
XPath.setSerializer((node, outer) => outer ? $E.html(node) : ($E(node).html() ?? ''));
const log = (...values) => { try { host('novel.log', (S ? `<${S.bookSourceName}> ` : '') + values.map(v => typeof v === 'string' ? v : safeJSON(v)).join(' ').slice(0, 1500)); } catch { } };
function safeJSON(v) { try { return JSON.stringify(v); } catch { return String(v); } }
const UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
class LegadoError extends Error { }
const fail = message => { throw new LegadoError(message); };

// --- Storage (the source's own profile, NovelRuntime) ------------------------------------------
// Per source (NovelStore), whichever runtime runs it.
const storeCall = (op, ns, key, value) => host('novel.store', JSON.stringify({ op, source: S?.bookSourceUrl ?? '', key: ns + ':' + String(key), value: value == null ? '' : String(value) }));
const store = {
    get(ns, key) { try { return storeCall('get', ns, key) ?? ''; } catch { return ''; } },
    set(ns, key, value) { try { storeCall('set', ns, key, value); } catch { } },
    remove(ns, key) { try { storeCall('remove', ns, key); } catch { } },
};

// --- Bytes and text ------------------------------------------------------------------------
const latin1 = bytes => { let s = ''; for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode.apply(null, Array.from(bytes.slice(i, i + 8192), b => b & 255)); return s; };
const bytesFromBase64 = b64 => { const s = atob(String(b64 ?? '').replace(/[^A-Za-z0-9+/=]/g, '')); const out = new Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out; };
const base64FromBytes = bytes => btoa(latin1(bytes));
const hexFromBytes = bytes => Array.from(bytes, b => ((b & 255) < 16 ? '0' : '') + (b & 255).toString(16)).join('');
const bytesFromHex = hex => { const clean = String(hex).replace(/[^0-9a-fA-F]/g, ''); const out = []; for (let i = 0; i + 1 < clean.length; i += 2) out.push(parseInt(clean.substr(i, 2), 16)); return out; };
const isUTF8 = cs => !cs || /^utf-?8$/i.test(String(cs).trim());
function encodeText(text, charset) {
    if (isUTF8(charset)) return Array.from(new TextEncoder().encode(String(text)));
    return bytesFromBase64(host('novel.encode', JSON.stringify({ text: String(text), encoding: String(charset) })));
}
function decodeBytes(bytes, charset) { return decodeBase64(base64FromBytes(bytes), charset); }
function decodeBase64(b64, charset) { return host('novel.decode', JSON.stringify({ base64: b64, encoding: isUTF8(charset) ? 'utf-8' : String(charset) })) ?? ''; }
const toBytes = value => {
    if (value == null) return [];
    if (typeof value === 'string') return encodeText(value);
    if (Array.isArray(value)) return value.map(b => b & 255);
    if (ArrayBuffer.isView(value)) return Array.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
    if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
    return encodeText(String(value));
};

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ensp: ' ', emsp: ' ', thinsp: ' ', zwnj: '‌', zwj: '‍',
    ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’', hellip: '…', mdash: '—', ndash: '–', middot: '·', bull: '•',
    copy: '©', reg: '®', trade: '™', times: '×', divide: '÷', laquo: '«', raquo: '»', deg: '°', plusmn: '±',
    sect: '§', para: '¶', yen: '¥', cent: '¢', pound: '£', euro: '€', iexcl: '¡', iquest: '¿', acute: '´', uml: '¨',
    larr: '←', rarr: '→', uarr: '↑', darr: '↓', hearts: '♥', star: '☆', shy: '­' };
function unescapeHtml(text) {
    return String(text).replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/g, (all, name) => {
        if (name[0] === '#') {
            const code = name[1] === 'x' || name[1] === 'X' ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
            try { return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : all; } catch { return all; }
        }
        return ENTITIES[name] ?? ENTITIES[name.toLowerCase()] ?? all;
    });
}

// --- Java regular expressions -------------------------------------------------------------
const regexCache = new Map();
function javaRegex(source, flags = '') {
    const key = flags + '\u0000' + source;
    if (regexCache.has(key)) return regexCache.get(key);
    let src = String(source), f = flags;
    const inline = /^\(\?([imsux]+)\)/.exec(src);
    if (inline) { src = src.slice(inline[0].length); for (const c of inline[1]) if ('ims'.includes(c) && !f.includes(c)) f += c; }
    src = src.replace(/\\Q([\s\S]*?)(\\E|$)/g, (_, text) => text.replace(/[.*+?^${}()|[\]\\\/]/g, '\\$&'))
        .replace(/\\A/g, '^').replace(/\\[zZ]/g, '$')
        .replace(/\\p\{(?:Is)?Han\}/g, '一-鿿').replace(/\\p\{(?:Is)?(?:Punct|P)\}/g, '!-/:-@\\[-`{-~　-〿＀-￯')
        .replace(/([*+?}])\+/g, '$1');
    let regex = null;
    try { regex = new RegExp(src, f); } catch { regex = null; }
    regexCache.set(key, regex);
    if (regexCache.size > 500) regexCache.delete(regexCache.keys().next().value);
    return regex;
}
// Java's replacement syntax: \x is a literal x, ${name} a named group.
function javaReplacement(text) {
    let out = '';
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (c === '\\' && i + 1 < text.length) { const n = text[++i]; out += n === '$' ? '$$' : n; }
        else if (c === '$' && text[i + 1] === '{') { const end = text.indexOf('}', i); if (end < 0) { out += '$$'; continue; } out += '$<' + text.slice(i + 2, end) + '>'; i = end; }
        else if (c === '$' && !/[0-9]/.test(text[i + 1] ?? '')) out += '$$';
        else out += c;
    }
    return out;
}
const javaFullMatch = (pattern, text) => { const regex = javaRegex(pattern); if (!regex) return false; const m = new RegExp(`^(?:${regex.source})$`, regex.flags).exec(text); return !!m; };

// Java String methods sources call on strings (Rhino hands them java.lang.String).
for (const [name, fn] of Object.entries({
    equals(other) { return String(this) === String(other); },
    equalsIgnoreCase(other) { return String(this).toLowerCase() === String(other).toLowerCase(); },
    isEmpty() { return this.length === 0; }, isBlank() { return String(this).trim().length === 0; },
    contains(text) { return String(this).includes(String(text)); },
    matches(pattern) { return javaFullMatch(pattern, String(this)); },
    replaceFirst(pattern, replacement) { const r = javaRegex(pattern); return r ? String(this).replace(r, javaReplacement(String(replacement))) : String(this); },
    compareTo(other) { return String(this) < String(other) ? -1 : String(this) > String(other) ? 1 : 0; },
    getBytes(charset) { return encodeText(String(this), charset); },
})) if (!(name in String.prototype)) Object.defineProperty(String.prototype, name, { value: fn, writable: true, configurable: true });
// Java lists: size() and get(i).
if (!('size' in Array.prototype)) Object.defineProperty(Array.prototype, 'size', { value() { return this.length; }, writable: true, configurable: true });
if (!('get' in Array.prototype)) Object.defineProperty(Array.prototype, 'get', { value(i) { return this[i]; }, writable: true, configurable: true });

// --- URLs ----------------------------------------------------------------------------------
const paramPattern = /\s*,\s*(?=\{)/;
function splitOptions(url) { const m = paramPattern.exec(url); return m ? [url.slice(0, m.index), url.slice(m.index + m[0].length)] : [url, null]; }
const isAbsUrl = u => /^https?:\/\//i.test(u);
const isDataUrl = u => /^data:/i.test(u);
function parseURL(u) {
    const m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(\/\/[^/?#]*)?([^?#]*)(\?[^#]*)?(#[\s\S]*)?$/.exec(u) || [];
    return { scheme: m[1] || '', auth: m[2] ?? null, path: m[3] || '', query: m[4] ?? null, frag: m[5] ?? null };
}
function removeDots(path) {
    const out = [];
    for (const seg of path.split('/')) { if (seg === '..') { if (out.length > 1) out.pop(); } else if (seg !== '.') out.push(seg); }
    let joined = out.join('/');
    if (/\/\.\.?$/.test(path)) joined += '/';
    return joined;
}
function resolveURL(base, rel) {
    const b = parseURL(base), r = parseURL(rel);
    let scheme, auth, path, query;
    if (r.scheme) { scheme = r.scheme; auth = r.auth; path = removeDots(r.path); query = r.query; }
    else if (r.auth !== null) { scheme = b.scheme; auth = r.auth; path = removeDots(r.path); query = r.query; }
    else {
        scheme = b.scheme; auth = b.auth;
        if (!r.path) { path = b.path; query = r.query ?? b.query; }
        else {
            path = r.path.startsWith('/') ? removeDots(r.path)
                : removeDots((b.auth !== null && !b.path ? '/' : b.path.slice(0, b.path.lastIndexOf('/') + 1)) + r.path);
            query = r.query;
        }
    }
    return scheme + (auth ?? '') + path + (query ?? '') + (r.frag ?? '');
}
/// NetworkUtils.getAbsoluteURL, keeping a `,{options}` suffix as it is.
function absoluteURL(base, relative) {
    const rel = String(relative ?? '').trim();
    if (!base) return rel;
    if (isAbsUrl(rel) || isDataUrl(rel)) return rel;
    if (/^javascript/i.test(rel)) return '';
    const [path, options] = splitOptions(rel);
    const [baseURL] = splitOptions(String(base));
    if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(baseURL)) return rel;
    try { return resolveURL(baseURL, path) + (options != null ? ',' + options : ''); } catch { return rel; }
}
const hostOf = url => { const m = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/(?:[^@/?#]*@)?([^:/?#]+)/.exec(String(url)); return m ? m[1].toLowerCase() : ''; };
function subDomain(url) {
    const host = hostOf(url) || String(url).toLowerCase();
    if (/^\d+\.\d+\.\d+\.\d+$/.test(host) || !host.includes('.')) return host;
    const parts = host.split('.');
    const two = parts.slice(-2).join('.');
    if (parts.length > 2 && /^(com|net|org|gov|edu|co|ac)\.[a-z]{2}$/.test(two)) return parts.slice(-3).join('.');
    return two;
}
const baseURLOf = url => { const m = /^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/?#,]*)/.exec(String(url)); return m ? m[1] : null; };

// --- Percent encoding (AnalyzeUrl.encodeParams) -------------------------------------------------
const percent = bytes => bytes.map(b => '%' + ((b & 255) < 16 ? '0' : '') + (b & 255).toString(16).toUpperCase()).join('');
const validPercents = s => !/%(?![0-9a-fA-F]{2})/.test(s);
const encodedQuery = s => /^[A-Za-z0-9\-._~!$&'()*+,;=:@/?%]*$/.test(s) && validPercents(s);
const encodedForm = s => /^[A-Za-z0-9\-._~!$'()*+,;:@/?%]*$/.test(s) && validPercents(s);
function formEncode(text, charset) {
    let out = '';
    for (const ch of String(text)) {
        if (/[A-Za-z0-9.*_-]/.test(ch)) out += ch;
        else if (ch === ' ') out += '+';
        else out += percent(encodeText(ch, charset));
    }
    return out;
}
function queryEncode(text, charset) {
    let out = '';
    const s = String(text);
    for (let i = 0; i < s.length; i++) {
        const ch = s[i];
        if (ch === '%' && /^[0-9a-fA-F]{2}$/.test(s.substr(i + 1, 2))) { out += ch; continue; }
        if (/[A-Za-z0-9\-._~!$&'()*+,;=:@/?]/.test(ch)) { out += ch; continue; }
        const cp = s.codePointAt(i); const full = String.fromCodePoint(cp); if (full.length > 1) i++;
        out += percent(encodeText(full, charset));
    }
    return out;
}
function encodeParams(params, charset, isQuery) {
    const checkEncoded = !charset;
    const cs = !charset ? 'utf-8' : charset === 'escape' ? null : charset;
    if (isQuery && cs != null) return encodedQuery(params) ? params : queryEncode(params, cs);
    const parts = [];
    for (const piece of String(params).split('&')) {
        const eq = piece.indexOf('=');
        const encode = v => checkEncoded && encodedForm(v) ? v : cs == null ? escape(v) : formEncode(v, cs);
        parts.push(eq < 0 ? encode(piece) : encode(piece.slice(0, eq)) + '=' + encode(piece.slice(eq + 1)));
    }
    return parts.join('&');
}
const isJsonText = s => { const t = String(s).trim(); return (t.startsWith('{') && t.endsWith('}')) || (t.startsWith('[') && t.endsWith(']')); };
const isXmlText = s => String(s).trim().startsWith('<');
function lenientJSON(text) {
    if (text == null) return null;
    if (typeof text !== 'string') return text;
    try { return JSON.parse(text); } catch { }
    try { return (0, eval)('(' + text + ')'); } catch { }
    // Gson's lenient mode also takes bare words as strings: {"keyword":斗破苍穹}.
    try {
        const quoted = text.replace(/([:\[,]\s*)([^\s"'{}\[\],:][^,}\]\n]*?)(\s*[,}\]\n])/g, (all, a, word, b) => /^(-?\d+(\.\d+)?|true|false|null)$/.test(word.trim()) ? all : a + JSON.stringify(word.trim()) + b);
        return (0, eval)('(' + quoted + ')');
    } catch { }
    return null;
}

// --- Cookies, cache, source (Legado's CookieStore, CacheManager, BaseSource) -----------------
const seenCookies = new Map();
const cookieMap = text => { const out = {}; for (const part of String(text ?? '').split(';')) { const i = part.indexOf('='); if (i > 0) out[part.slice(0, i).trim()] = part.slice(i + 1).trim(); } return out; };
const cookieText = map => Object.entries(map).filter(([k, v]) => k && v != null && v !== '').map(([k, v]) => `${k}=${v}`).join('; ');
const cookie = {
    getCookie(url) { const d = subDomain(url); return cookieText({ ...(seenCookies.get(d) ?? {}), ...cookieMap(store.get('cookie', d)) }); },
    getKey(url, key) { return cookieMap(this.getCookie(url))[key] ?? ''; },
    setCookie(url, text) { store.set('cookie', subDomain(url), text ?? ''); },
    replaceCookie(url, text) { const d = subDomain(url); store.set('cookie', d, cookieText({ ...cookieMap(store.get('cookie', d)), ...cookieMap(text) })); },
    removeCookie(url) { const d = subDomain(url); store.remove('cookie', d); seenCookies.delete(d); },
    cookieToMap: cookieMap, mapToCookie: cookieText,
    absorb(url, fields) { if (!fields || !Object.keys(fields).length) return; const d = subDomain(url); seenCookies.set(d, { ...(seenCookies.get(d) ?? {}), ...fields }); },
    manual(url) { return store.get('cookie', subDomain(url)); },
};
const memoryCache = new Map();
const cache = {
    get(key) {
        const text = store.get('cache', key);
        if (!text) return memoryCache.get(String(key)) ?? null;
        try { const v = JSON.parse(text); if (v.e && v.e < Date.now()) { store.remove('cache', key); return null; } return v.v; } catch { return null; }
    },
    put(key, value, saveTime = 0) {
        const v = typeof value === 'string' ? value : safeJSON(value);
        store.set('cache', key, JSON.stringify({ v, e: saveTime > 0 ? Date.now() + saveTime * 1000 : 0 }));
    },
    delete(key) { store.remove('cache', key); memoryCache.delete(String(key)); },
    putMemory(key, value) { memoryCache.set(String(key), value); }, getFromMemory(key) { return memoryCache.get(String(key)) ?? null; }, deleteMemory(key) { memoryCache.delete(String(key)); },
    getFile(key) { return this.get(key); }, putFile(key, value, saveTime = 0) { this.put(key, value, saveTime); },
    getInt(key) { const v = this.get(key); return v == null ? null : parseInt(v); }, getLong(key) { return this.getInt(key); }, getDouble(key) { const v = this.get(key); return v == null ? null : parseFloat(v); },
};

let S = null;        // the source's JSON
let source = null;   // the source as scripts see it
function makeSource(json) {
    const key = String(json.bookSourceUrl ?? '');
    return Object.assign(Object.create({
        getKey() { return key; }, getTag() { return json.bookSourceName ?? key; },
        put(k, v) { store.set('v', k, v); return v; }, get(k) { return store.get('v', k); },
        getVariable() { return store.get('sourceVariable', 'v'); }, putVariable(v) { if (v == null) store.remove('sourceVariable', 'v'); else store.set('sourceVariable', 'v', v); },
        setVariable(v) { this.putVariable(v); },
        getLoginInfo() { return store.get('login', 'info') || null; }, getLoginInfoMap() { return lenientJSON(store.get('login', 'info')) ?? {}; },
        putLoginInfo(info) { store.set('login', 'info', info); return true; }, removeLoginInfo() { store.remove('login', 'info'); },
        getLoginHeader() { return store.get('login', 'header') || null; }, getLoginHeaderMap() { return lenientJSON(store.get('login', 'header')) ?? null; },
        putLoginHeader(header) { store.set('login', 'header', header); }, removeLoginHeader() { store.remove('login', 'header'); },
        getHeaderMap(hasLoginHeader = false) { return headerMap(hasLoginHeader); },
        evalJS(js) { return new Analyzer({}).evalJS(String(js), null); },
        refreshExplore() { exploreKindsKept = null; }, refreshJSLib() { }, getConcurrentRate() { return json.concurrentRate ?? null; },
        getDisplayNameGroup() { return json.bookSourceName ?? ''; },
    }), json);
}
function headerMap(hasLoginHeader = true) {
    const map = {};
    let header = S?.header;
    if (header) {
        try {
            const text = String(header).trim();
            const js = /^@js:/i.test(text) ? text.slice(4) : /^<js>/i.test(text) ? text.slice(4, text.lastIndexOf('<')) : null;
            const value = js != null ? new Analyzer({}).evalJS(js, null) : text;
            const parsed = typeof value === 'object' && value ? value : lenientJSON(String(value));
            if (parsed && typeof parsed === 'object') for (const [k, v] of Object.entries(parsed)) if (v != null) map[k] = String(v);
        } catch (error) { log('header rule failed', String(error?.message ?? error)); }
    }
    if (!Object.keys(map).some(k => k.toLowerCase() === 'user-agent')) map['User-Agent'] = UA;
    if (hasLoginHeader) { const login = lenientJSON(store.get('login', 'header')); if (login && typeof login === 'object') for (const [k, v] of Object.entries(login)) map[k] = String(v); }
    return map;
}

// --- Books and chapters as scripts see them (Legado's Book, SearchBook, BookChapter) -----------
class RuleData {
    constructor(variables) { this.variableMap = { ...(variables ?? {}) }; }
    putVariable(key, value) { if (value == null) delete this.variableMap[key]; else this.variableMap[key] = String(value); return true; }
    getVariable(key) { if (key === undefined) return this.variableMap.custom ?? ''; return this.variableMap[key] ?? ''; }
    getCustomVariable() { return this.variableMap.custom ?? ''; }
    putCustomVariable(value) { this.putVariable('custom', value); }
    get variable() { return JSON.stringify(this.variableMap); }
    set variable(text) { const v = lenientJSON(text); if (v && typeof v === 'object') this.variableMap = { ...v }; }
}
class Book extends RuleData {
    constructor(fields = {}) {
        super(fields.variables);
        this.bookUrl = fields.url ?? ''; this.tocUrl = fields.tocURL ?? ''; this.name = fields.name ?? ''; this.author = fields.author ?? '';
        this.kind = fields.kind ?? ''; this.intro = fields.intro ?? ''; this.coverUrl = fields.cover ?? ''; this.latestChapterTitle = fields.lastChapter ?? '';
        this.wordCount = fields.wordCount ?? ''; this.origin = S?.bookSourceUrl ?? ''; this.originName = S?.bookSourceName ?? '';
        this.durChapterIndex = 0; this.durChapterTitle = ''; this.totalChapterNum = 0; this.type = 8; this.customIntro = null; this.customCoverUrl = null; this.infoHtml = null; this.tocHtml = null;
    }
    getRealAuthor() { return this.author; }
    getUnreadChapterNum() { return 0; }
    getDisplayCover() { return this.coverUrl; }
    getDisplayIntro() { return this.intro; }
    toNovel() {
        return { sourceKey: S.bookSourceUrl, url: String(this.bookUrl ?? ''), name: String(this.name ?? ''), author: String(this.author ?? ''), kind: String(this.kind ?? ''),
            intro: String(this.intro ?? ''), cover: String(this.coverUrl ?? ''), lastChapter: String(this.latestChapterTitle ?? ''), wordCount: String(this.wordCount ?? ''),
            tocURL: String(this.tocUrl ?? ''), variables: stringMap(this.variableMap) };
    }
}
class Chapter extends RuleData {
    constructor(fields = {}, bookUrl = '', baseUrl = '') {
        super(fields.variables);
        this.title = fields.title ?? ''; this.url = fields.url ?? ''; this.index = fields.index ?? 0; this.isVolume = !!fields.isVolume; this.isVip = !!fields.isVip;
        this.isPay = false; this.tag = fields.tag ?? ''; this.bookUrl = bookUrl; this.baseUrl = baseUrl; this.resourceUrl = null; this.wordCount = null; this.imgUrl = null; this.start = null; this.end = null;
    }
    getAbsoluteURL() {
        if (this.isVolume && this.url.startsWith(this.title)) return this.baseUrl;
        return absoluteURL(this.baseUrl, this.url);
    }
    getDisplayTitle() { return this.title; }
    toNovel() { return { index: this.index, title: String(this.title ?? ''), url: this.isVolume && String(this.url).startsWith(this.title) ? String(this.url) : this.getAbsoluteURL(), isVolume: !!this.isVolume, isVip: !!(this.isVip || this.isPay), tag: String(this.tag ?? ''), variables: stringMap(this.variableMap) }; }
}
const stringMap = map => Object.fromEntries(Object.entries(map ?? {}).filter(([, v]) => v != null).map(([k, v]) => [k, String(v)]));

// --- Responses -------------------------------------------------------------------------------
class StrResponse {
    constructor(url, body, code = 200, headers = {}, message = '') { this._url = url; this._body = body; this._code = code; this._headers = headers; this._message = message; }
    body() { return this._body; } code() { return this._code; } url() { return this._url; } message() { return this._message; }
    headers() { return this._headers; } header(name) { return this._headers[String(name).toLowerCase()] ?? null; }
    isSuccessful() { return this._code >= 200 && this._code < 300; }
    raw() { const self = this; return { request() { return { url() { return self._url; } }; }, code() { return self._code; }, headers() { return self._headers; } }; }
    toString() { return String(this._body ?? ''); }
    callTime() { return 0; }
}
// Jsoup's Connection.Response, for java.get/post/head.
class JsoupResponse extends StrResponse {
    statusCode() { return this._code; } statusMessage() { return this._message; }
    cookies() { return cookieMap(this._headers['set-cookie'] ?? ''); } cookie(name) { return this.cookies()[name] ?? null; }
    parse() { return parseDocument(this._body); }
}

// --- HTTP ------------------------------------------------------------------------------------
let requestCount = 0, deadline = Infinity;
const tracing = (() => { try { return host('novel.flag', 'trace') === '1'; } catch { return false; } })();
const hasHeader = (headers, name) => Object.keys(headers).some(k => k.toLowerCase() === name.toLowerCase());
function sendHTTP({ url, method = 'GET', headers = {}, body = null, timeout = 15000 }) {
    if (++requestCount > 400) fail('This source made too many requests.');
    const left = deadline - Date.now();
    if (left < 500) fail('The book source took too long to answer.');
    const request = { url, method, headers: { ...headers }, timeout: Math.min(timeout, left), jar: String(S?.bookSourceUrl ?? '') };
    if (!hasHeader(request.headers, 'User-Agent')) request.headers['User-Agent'] = UA;
    if (!hasHeader(request.headers, 'Cookie')) { const manual = cookie.manual(url); if (manual) request.headers.Cookie = manual; }
    if (body != null && method !== 'GET' && method !== 'HEAD') request.body = body;
    const answer = JSON.parse(host('novel.http', JSON.stringify(request)));
    if (tracing) log(`http ${method} ${url} ${body ? 'body=' + String(body).slice(0, 200) + ' ' : ''}→ ${answer.code} ${answer.failed ?? ''} ${(answer.base64 ?? '').length * 3 / 4 | 0}B ${answer.url !== url ? '→ ' + answer.url : ''}`);
    if (answer.cookies) cookie.absorb(answer.url || url, answer.cookies);
    if (answer.failed) fail(answer.failed);
    return answer;
}
function decodeAnswer(answer, charset) {
    const b64 = answer.base64 ?? '';
    let cs = charset;
    if (!cs) { const m = /charset\s*=\s*["']?([\w-]+)/i.exec(answer.headers?.['content-type'] ?? ''); if (m) cs = m[1]; }
    if (!cs) {
        const head = latin1(bytesFromBase64(b64.slice(0, 5464)));
        const m = /<meta[^>]+charset\s*=\s*["']?\s*([\w-]+)/i.exec(head) || /<\?xml[^>]+encoding\s*=\s*["']([\w-]+)/i.exec(head);
        if (m) cs = m[1];
    }
    return decodeBase64(b64, cs);
}

/// AnalyzeUrl: a rule URL (`url,{options}`, JS, {{}} templates, <page,lists>) made into a request.
function buildRequest(ruleUrl, { key = null, page = null, baseUrl = '', book = null, chapter = null, ruleData = null } = {}) {
    const an = new Analyzer({ ruleData: ruleData ?? book, chapter });
    an.locals = { key, page };
    an.baseUrl = baseUrl;
    let base = splitOptions(String(baseUrl ?? ''))[0];
    an.baseUrl = base;
    // JS segments: each gets the previous result (`@result` in the plain parts).
    let url = String(ruleUrl ?? '');
    {
        const re = /<js>([\s\S]*?)<\/js>|@js:([\s\S]*)/gi;
        let start = 0, m, result = url, found = false;
        while ((m = re.exec(url))) {
            found = true;
            const plain = url.slice(start, m.index).trim();
            if (plain) result = plain.replace(/@result/g, result);
            result = jsString(an.evalJS(m[2] ?? m[1], result));
            start = m.index + m[0].length;
        }
        if (found) { const plain = url.slice(start).trim(); if (plain) result = plain.replace(/@result/g, result); url = result; }
    }
    // {{js}}, then <page,lists>.
    if (url.includes('{{') && url.includes('}}')) {
        url = url.replace(/\{\{([\s\S]*?)\}\}/g, (_, code) => jsString(an.evalJS(code, null)));
    }
    if (page != null) {
        url = url.replace(/<(.*?)>/g, (all, list) => { const pages = list.split(','); return (page < pages.length ? pages[page - 1] : pages[pages.length - 1]).trim(); });
    }
    // Legado 2's searchKey/searchPage.
    if (key != null) url = url.replace(/searchKey/g, key);
    if (page != null) url = url.replace(/searchPage([-+]1)?/g, (_, step) => String(page + (step ? Number(step) : 0)));
    const [plain, optionText] = splitOptions(url);
    const request = { ruleUrl: url, url: absoluteURL(base, plain), method: 'GET', headers: headerMap(true), body: null, charset: null, type: null, retry: 0, webView: false, webJs: null };
    if (optionText != null) {
        const option = lenientJSON(optionText);
        if (option && typeof option === 'object') {
            if (option.method) request.method = /^post$/i.test(option.method) ? 'POST' : /^head$/i.test(option.method) ? 'HEAD' : 'GET';
            const headers = typeof option.headers === 'string' ? lenientJSON(option.headers) : option.headers;
            if (headers && typeof headers === 'object') for (const [k, v] of Object.entries(headers)) request.headers[k] = String(v);
            if (option.body != null) request.body = typeof option.body === 'string' ? option.body : JSON.stringify(option.body);
            request.type = option.type ?? null; request.charset = option.charset ?? null; request.retry = Number(option.retry) || 0;
            request.webView = option.webView === true || String(option.webView) === 'true'; request.webJs = option.webJs ?? null;
            if (option.js) { const v = an.evalJS(String(option.js), request.url); if (v != null) request.url = jsString(v); }
        } else log('bad URL options', optionText.slice(0, 200));
    }
    request.urlNoQuery = request.url;
    if (request.method === 'POST') {
        if (request.body != null && !isJsonText(request.body) && !isXmlText(request.body) && !hasHeader(request.headers, 'Content-Type')) request.encodedForm = encodeParams(request.body, request.charset, false);
    } else {
        const q = request.url.indexOf('?');
        if (q >= 0) { request.encodedQuery = encodeParams(request.url.slice(q + 1), request.charset, true); request.urlNoQuery = request.url.slice(0, q); }
    }
    return request;
}
const jsString = v => v == null ? '' : typeof v === 'number' && Number.isInteger(v) ? String(v) : typeof v === 'object' && !(v instanceof StrResponse) && !isNode(v) && !Array.isArray(v) ? safeJSON(v) : String(v);

const isBotCheck = (code, text) => ((code === 202 || code === 403 || code === 503) && String(text).length < 30000 &&
    /<title>Just a moment\.\.\.<\/title>|\/probe\.js|challenge-platform|cf-browser-verification|__gatekeeper_challenge/.test(String(text))) || isRedirectStub(text);
/// A cookie check that is nothing but a script sending the browser on (`location.replace(url + token)`).
const isRedirectStub = text => { const t = String(text); return t.length < 2000 && /<script[^>]*>[^<]*location(\.href)?\s*(=|\.replace\(|\.assign\()/.test(t) && !t.replace(/<script[\s\S]*?<\/script>|<title>[\s\S]*?<\/title>|<[^>]+>/g, '').replace(/Redirecting|Loading\.*/gi, '').trim(); };
/// A page as a browser renders it (NovelWebView): {content, url}.
function webView({ url = null, html = null, js = null, headers = {}, challenge = false }) {
    const left = deadline - Date.now();
    if (left < 4000) fail('The book source took too long to answer.');
    const agent = Object.entries(headers).find(([k]) => k.toLowerCase() === 'user-agent')?.[1] ?? Object.entries(headerMap(false)).find(([k]) => k.toLowerCase() === 'user-agent')?.[1] ?? UA;
    if (tracing) log(`webview ${url ?? '(html)'}${js ? ' js' : ''}${challenge ? ' (check)' : ''}`);
    const answer = JSON.parse(host('novel.webview', JSON.stringify({ url, html, js, ua: agent, headers, jar: String(S?.bookSourceUrl ?? ''), timeout: Math.min(25, left / 1000 - 2), challenge })));
    if (answer.failed) fail(answer.failed);
    return { content: String(answer.content ?? ''), url: String(answer.url || url || '') };
}
function perform(request) {
    if (request.webView && !isDataUrl(request.url)) {
        const url = request.encodedQuery != null ? request.urlNoQuery + '?' + request.encodedQuery : request.url;
        const page = webView({ url, js: request.webJs, headers: request.headers });
        return new StrResponse(page.url || url, page.content, 200, {});
    }
    let lastError;
    const tries = Math.min(Math.max(request.retry || 0, 0), 3) + 1;
    for (let attempt = 0; attempt < tries; attempt++) {
        try {
            const headers = { ...request.headers };
            let url = request.url, body = null;
            if (request.method === 'POST') {
                url = request.urlNoQuery;
                if (request.encodedForm != null || !String(request.body ?? '').trim()) {
                    body = request.encodedForm ?? '';
                    if (!hasHeader(headers, 'Content-Type')) headers['Content-Type'] = 'application/x-www-form-urlencoded';
                } else {
                    body = request.body;
                    if (!hasHeader(headers, 'Content-Type')) headers['Content-Type'] = 'application/json; charset=UTF-8';
                }
            } else if (request.encodedQuery != null) url = request.urlNoQuery + '?' + request.encodedQuery;
            if (isDataUrl(url)) {
                const m = /^data:([^,]*?)(;base64)?,([\s\S]*)$/i.exec(url);
                const text = m ? (m[2] ? decodeBase64(m[3], request.charset) : decodeURIComponent(m[3])) : '';
                return new StrResponse(url, text, 200, {});
            }
            const answer = sendHTTP({ url, method: request.method, headers, body });
            const text = request.type ? hexFromBytes(bytesFromBase64(answer.base64 ?? '')) : decodeAnswer(answer, request.charset);
            // A bot check a browser passes by itself (Cloudflare, a probe.js page): pass it in the web view, whose
            // cookies then go with the source's next requests.
            let checkFailure = null;
            if (request.method === 'POST' && !request.type && isBotCheck(answer.code, text)) {
                // The check passed on the site's front page, then the form again with its cookies.
                try {
                    webView({ url: url.replace(/^(https?:\/\/[^/?#]+).*$/i, '$1/'), headers, challenge: true });
                    const again = sendHTTP({ url, method: request.method, headers, body });
                    const retried = decodeAnswer(again, request.charset);
                    if (!isBotCheck(again.code, retried)) return new StrResponse(again.url || url, retried, again.code ?? 0, again.headers ?? {});
                }
                catch (error) { checkFailure = String(error?.message ?? error); log('bot check not passed:', checkFailure); }
            }
            if (request.method === 'GET' && !request.type && isBotCheck(answer.code, text)) {
                try {
                    const page = webView({ url, headers, challenge: true });
                    // The request again, now with the check's cookies: the page as the source's rules expect it
                    // (a browser may land elsewhere, such as a site's mobile pages).
                    const again = sendHTTP({ url, method: 'GET', headers });
                    const retried = decodeAnswer(again, request.charset);
                    if (!isBotCheck(again.code, retried)) return new StrResponse(again.url || url, retried, again.code ?? 0, again.headers ?? {});
                    if (!isBotCheck(200, page.content)) return new StrResponse(page.url || url, page.content, 200, {});
                }
                catch (error) { checkFailure = String(error?.message ?? error); log('bot check not passed:', checkFailure); }
            }
            // Still the check: say so, instead of handing the rules a page that has no books on it ("No Books" on
            // Apple TV, which has no web view). A source's loginCheckJs may deal with the page itself.
            if (!request.type && !S?.loginCheckJs && isBotCheck(answer.code, text)) {
                fail(checkFailure && /web browser/.test(checkFailure) ? checkFailure : "The site's browser check didn't pass. Try again later.");
            }
            return new StrResponse(answer.url || url, text, answer.code ?? 0, answer.headers ?? {});
        } catch (error) { lastError = error; }
    }
    throw lastError;
}
/// A request plus the source's loginCheckJs, which may replace the response.
function performChecked(request, context = {}) {
    const response = perform(request);
    if (!S.loginCheckJs) return response;
    const an = new Analyzer({ ruleData: context.ruleData ?? context.book, chapter: context.chapter });
    an.baseUrl = request.url;
    const checked = an.evalJS(S.loginCheckJs, response);
    return checked instanceof StrResponse ? checked : response;
}

// --- HTML (Jsoup's view of cheerio's DOM) ---------------------------------------------------
const isElement = node => node && (node.type === 'tag' || node.type === 'script' || node.type === 'style');
const isNode = value => value != null && typeof value === 'object' && typeof value.type === 'string' && 'parent' in value && !Array.isArray(value);
const kids = node => (node && node.children) || [];
const elementChildren = node => kids(node).filter(isElement);
function parseDocument(text) {
    const html = String(text ?? '');
    let wrapped = html;
    if (/^\s*<\?xml/i.test(html)) return cheerio.load(html, { xml: true }).root()[0];
    if (/<\/td>\s*$/i.test(wrapped)) wrapped = `<tr>${wrapped}</tr>`;
    if (/<\/(tr|tbody)>\s*$/i.test(wrapped) && !/<table/i.test(wrapped)) wrapped = `<table>${wrapped}</table>`;
    return cheerio.load(wrapped).root()[0];
}
const outerHTML = node => isNode(node) ? $E.html(node) : String(node ?? '');
const innerHTML = node => isNode(node) ? ($E(node).html() ?? '') : String(node ?? '');
function collect(root, test) {
    const out = [];
    const walk = n => { if (isElement(n) && test(n)) out.push(n); for (const c of kids(n)) walk(c); };
    walk(root);
    return out;
}
const classesOf = el => String(el.attribs?.class ?? '').split(/\s+/).filter(Boolean);
/// Jsoup's hasClass: one of the classes, or the whole class attribute (`class.a b` finds class="a b").
const hasClass = (el, name) => { const want = String(name).toLowerCase(); const all = String(el.attribs?.class ?? ''); return all.toLowerCase() === want || classesOf(el).some(c => c.toLowerCase() === want); };
function cssSelect(root, selector) {
    let sel = String(selector).trim();
    if (!sel) return [];
    sel = sel.replace(/:containsOwn\(/g, ':contains(').replace(/:matchesOwn\(/g, ':matches(')
        // Jsoup takes unquoted attribute values with spaces: div[class=a b].
        .replace(/\[\s*([\w-]+)\s*([~|^$*]?=)\s*([^\]"']*?)\s*\]/g, (all, name, op, value) => /^[\w-]+$/.test(value) ? all : `[${name}${op}${JSON.stringify(value)}]`);
    try {
        const $r = $E(root);
        const found = $r.find(sel).toArray();
        if (isElement(root)) { try { if ($r.is(sel)) found.unshift(root); } catch { } }
        return found;
    } catch (error) { log('css', sel, String(error?.message ?? error)); return []; }
}
function attrOf(el, name, base) {
    if (!isElement(el)) return '';
    if (name.startsWith('abs:')) { const v = attrOf(el, name.slice(4)); return v ? absoluteURL(base, v) : ''; }
    const attribs = el.attribs ?? {};
    if (name in attribs) return String(attribs[name]);
    const lower = name.toLowerCase();
    for (const [k, v] of Object.entries(attribs)) if (k.toLowerCase() === lower) return String(v);
    return '';
}

// Jsoup's Element API on cheerio nodes, for scripts that call java.getElements(...)[0].text() and the like.
{
    // On NodeWithChildren, so documents (org.jsoup.Jsoup.parse) have them too.
    const proto = Object.getPrototypeOf(Object.getPrototypeOf(cheerio.load('<b></b>')('b')[0]));
    const methods = {
        text() { return XPath.jsoupText(this); }, ownText() { return XPath.ownText(this); }, html() { return innerHTML(this); }, outerHtml() { return outerHTML(this); },
        attr(name, value) { if (value !== undefined) { this.attribs[name] = String(value); return this; } return attrOf(this, String(name), ''); },
        hasAttr(name) { return attrOf(this, String(name), '') !== ''; }, absUrl(name) { return attrOf(this, String(name), ''); },
        select(css) { return cssSelect(this, css); }, selectFirst(css) { return cssSelect(this, css)[0] ?? null; },
        children() { return elementChildren(this); }, child(i) { return elementChildren(this)[i] ?? null; }, parent() { return this.parent; },
        tagName() { return this.name; }, nodeName() { return this.name; }, id() { return this.attribs?.id ?? ''; }, className() { return this.attribs?.class ?? ''; },
        classNames() { return classesOf(this); }, hasClass(c) { return hasClass(this, c); }, data() { return this.name === 'script' || this.name === 'style' ? kids(this).map(n => n.data ?? '').join('') : ''; },
        getElementsByTag(tag) { return collect(this, e => e.name === String(tag).toLowerCase()); }, getElementsByClass(c) { return collect(this, e => hasClass(e, c)); },
        getElementById(id) { return collect(this, e => e.attribs?.id === id)[0] ?? null; }, textNodes() { return XPath.textNodes(this).map(n => ({ text: () => XPath.normalize(n.data ?? '').trim(), getWholeText: () => n.data ?? '' })); },
        nextElementSibling() { let n = this.next; while (n && !isElement(n)) n = n.next; return n ?? null; }, previousElementSibling() { let n = this.prev; while (n && !isElement(n)) n = n.prev; return n ?? null; },
        remove() { $E(this).remove(); }, toString() { return outerHTML(this); },
    };
    for (const [name, fn] of Object.entries(methods)) if (!Object.prototype.hasOwnProperty.call(proto, name)) Object.defineProperty(proto, name, { value: fn, writable: true, configurable: true });
}

/// Jsoup text getters at the end of a default rule (AnalyzeByJSoup.getResultLast).
function resultLast(elements, last, base) {
    const out = [];
    switch (last) {
        case 'text': for (const el of elements) { const t = XPath.jsoupText(el); if (t) out.push(t); } break;
        case 'textNodes': for (const el of elements) { const t = XPath.textNodes(el).map(n => XPath.normalize(n.data ?? '').trim()).filter(Boolean); if (t.length) out.push(t.join('\n')); } break;
        case 'ownText': for (const el of elements) { const t = XPath.ownText(el); if (t) out.push(t); } break;
        case 'html': {
            for (const el of elements) for (const s of cssSelect(el, 'script, style')) $E(s).remove();
            const html = elements.map(outerHTML).join('\n');
            if (html) out.push(html);
            break;
        }
        case 'all': out.push(elements.map(outerHTML).join('\n')); break;
        default: for (const el of elements) { const v = attrOf(el, last, base); if (!v.trim() || out.includes(v)) continue; out.push(v); }
    }
    return out;
}

/// AnalyzeByJSoup.ElementsSingle: `class.x.0`, `tag.li!0`, `children[1:3]`, or a CSS selector.
function findIndexSet(rule) {
    const rus = rule.trim();
    const info = { split: '.', beforeRule: '', indexDefault: [], indexes: [] };
    let len = rus.length, curMinus = false, l = '';
    const curList = [];
    if (rus[rus.length - 1] === ']') {
        len--;
        while (len-- >= 0) {
            let rl = rus[len];
            if (rl === undefined) break;
            if (rl === ' ') continue;
            if (rl >= '0' && rl <= '9') l = rl + l;
            else if (rl === '-') curMinus = true;
            else {
                const curInt = l === '' ? null : curMinus ? -parseInt(l) : parseInt(l);
                if (rl === ':') curList.push(curInt);
                else {
                    if (!curList.length) { if (curInt == null) break; info.indexes.push(curInt); }
                    else { info.indexes.push({ start: curInt, end: curList[curList.length - 1], step: curList.length === 2 ? curList[0] : 1 }); curList.length = 0; }
                    if (rl === '!') { info.split = '!'; do { rl = rus[--len]; } while (len > 0 && rl === ' '); }
                    if (rl === '[') { info.beforeRule = rus.slice(0, len); return info; }
                    if (rl !== ',') break;
                }
                l = ''; curMinus = false;
            }
        }
    } else {
        while (len-- >= 0) {
            const rl = rus[len];
            if (rl === undefined) break;
            if (rl === ' ') continue;
            if (rl >= '0' && rl <= '9') l = rl + l;
            else if (rl === '-') curMinus = true;
            else {
                if ((rl === '!' || rl === '.' || rl === ':') && l !== '') {
                    info.indexDefault.push(curMinus ? -parseInt(l) : parseInt(l));
                    if (rl !== ':') { info.split = rl; info.beforeRule = rus.slice(0, len); return info; }
                } else break;
                l = ''; curMinus = false;
            }
        }
    }
    info.split = ' '; info.beforeRule = rus; info.indexDefault = []; info.indexes = [];
    return info;
}
function elementsSingle(temp, rule) {
    const { split, beforeRule, indexDefault, indexes } = findIndexSet(rule);
    let elements;
    if (!beforeRule) elements = elementChildren(temp);
    else {
        const rules = beforeRule.split('.');
        switch (rules[0]) {
            case 'children': elements = elementChildren(temp); break;
            case 'class': elements = rules[1] ? collect(temp, e => hasClass(e, rules[1])) : []; break;
            case 'tag': elements = rules[1] ? collect(temp, e => e.name === rules[1].toLowerCase()) : []; break;
            case 'id': elements = rules[1] ? collect(temp, e => e.attribs?.id === rules[1]) : []; break;
            case 'text': elements = rules[1] ? collect(temp, e => XPath.ownText(e).toLowerCase().includes(rules.slice(1).join('.').toLowerCase())) : []; break;
            default: elements = cssSelect(temp, beforeRule);
        }
    }
    const len = elements.length;
    const last = indexDefault.length ? indexDefault.length - 1 : indexes.length - 1;
    const set = new Set();
    if (!indexes.length) {
        for (let ix = last; ix >= 0; ix--) { const it = indexDefault[ix]; if (it >= 0 && it < len) set.add(it); else if (it < 0 && len >= -it) set.add(it + len); }
    } else {
        for (let ix = last; ix >= 0; ix--) {
            const item = indexes[ix];
            if (typeof item === 'object') {
                let start = item.start ?? 0; if (start < 0) start += len;
                let end = item.end ?? (len - 1); if (end < 0) end += len;
                if ((start < 0 && end < 0) || (start >= len && end >= len)) continue;
                start = Math.max(0, Math.min(start, len - 1)); end = Math.max(0, Math.min(end, len - 1));
                if (start === end || item.step >= len) { set.add(start); continue; }
                const step = item.step > 0 ? item.step : -item.step < len ? item.step + len : 1;
                if (end > start) for (let i = start; i <= end; i += step) set.add(i); else for (let i = start; i >= end; i -= step) set.add(i);
            } else if (item >= 0 && item < len) set.add(item);
            else if (item < 0 && len >= -item) set.add(item + len);
        }
    }
    if (split === '!') { const drop = new Set(set); return elements.filter((_, i) => !drop.has(i)); }
    if (split === '.') return [...set].map(i => elements[i]);
    return elements;
}

/// RuleAnalyzer.splitRule: splits on the first of `seps` found outside [] and (), then only on that one.
function splitRule(text, seps) {
    const parts = [];
    let type = '', from = 0, i = 0;
    while (i < text.length) {
        const c = text[i];
        if (c === '[' || c === '(') { const end = balanced(text, i, c, c === '[' ? ']' : ')'); if (end > 0) { i = end; continue; } }
        const sep = type ? (text.startsWith(type, i) ? type : null) : seps.find(s => text.startsWith(s, i));
        if (sep) { if (!type) type = sep; parts.push(text.slice(from, i)); i += sep.length; from = i; continue; }
        i++;
    }
    parts.push(text.slice(from));
    return { parts, type };
}
function balanced(text, pos, open, close) {
    let depth = 0, single = false, double = false;
    for (let i = pos; i < text.length; i++) {
        const c = text[i];
        if (c === "'" && !double) single = !single;
        else if (c === '"' && !single) double = !double;
        if (single || double) continue;
        if (c === '\\') { i++; continue; }
        if (c === open) depth++;
        else if (c === close) { depth--; if (depth === 0) return i + 1; }
    }
    return -1;
}
const trimRule = text => text.replace(/^[@\s\x00-\x20]+/, '');
function combine(lists, type) {
    if (!lists.length) return [];
    if (type === '%%') { const out = []; for (let i = 0; i < lists[0].length; i++) for (const l of lists) if (i < l.length) out.push(l[i]); return out; }
    return lists.flat();
}
function jsoupElements(temp, rule) {
    if (!temp || !rule) return [];
    const css = /^@CSS:/i.test(rule);
    const elementsRule = css ? rule.slice(5).trim() : rule;
    const { parts, type } = splitRule(elementsRule, ['&&', '||', '%%']);
    const lists = [];
    for (const ruleStr of parts) {
        let found;
        if (css) found = cssSelect(temp, ruleStr);
        else {
            const rs = splitRule(trimRule(ruleStr), ['@']).parts;
            if (rs.length > 1) {
                let el = [temp];
                for (const rl of rs) { const next = []; for (const et of el) next.push(...jsoupElements(et, rl)); el = next; }
                found = el;
            } else found = elementsSingle(temp, ruleStr);
        }
        lists.push(found);
        if (found.length && type === '||') break;
    }
    return combine(lists, type);
}
function jsoupStringList(temp, rule, base) {
    if (!rule) return [];
    const css = /^@CSS:/i.test(rule);
    const elementsRule = css ? rule.slice(5).trim() : rule;
    if (!elementsRule) return [''];
    const { parts, type } = splitRule(elementsRule, ['&&', '||', '%%']);
    const results = [];
    for (const ruleStr of parts) {
        let found = null;
        if (css) {
            const at = ruleStr.lastIndexOf('@');
            found = at < 0 ? resultLast(cssSelect(temp, ruleStr), 'text', base) : resultLast(cssSelect(temp, ruleStr.slice(0, at)), ruleStr.slice(at + 1).trim(), base);
        } else {
            const rules = splitRule(trimRule(ruleStr), ['@']).parts;
            let elements = [temp];
            for (let i = 0; i < rules.length - 1; i++) { const next = []; for (const el of elements) next.push(...elementsSingle(el, rules[i])); elements = next; }
            found = elements.length ? resultLast(elements, rules[rules.length - 1].trim(), base) : null;
        }
        if (found && found.length) { results.push(found); if (type === '||') break; }
    }
    return combine(results, type);
}

// --- JSONPath (Jayway's semantics on jsonpath-plus) ------------------------------------------------
const definitePath = path => !/\[\s*\*\s*\]|\.\.|\?\(|\.\*|\[[^\]'"]*[,:][^\]'"]*\]/.test(path);
function jsonRead(ctx, path) {
    let p = String(path).trim();
    if (!p.startsWith('$') && !p.startsWith('@')) p = p.startsWith('[') ? '$' + p : '$.' + p;
    if (p.startsWith('@')) p = '$' + p.slice(1);
    const matches = cheerio.jp(p, ctx) ?? [];
    if (definitePath(p)) { if (!matches.length) throw new Error('No results for path: ' + p); return matches[0]; }
    return matches;
}
const jsonText = v => v == null ? '' : typeof v === 'object' ? safeJSON(v) : String(v);
function innerRule(text, startToken, evaluate) {
    let out = '', from = 0, pos = 0, replaced = false;
    while ((pos = text.indexOf(startToken, pos)) >= 0) {
        const end = balanced(text, pos, '{', '}');
        if (end > 0) {
            const value = evaluate(text.slice(pos + 1, end - 1));
            if (value) { out += text.slice(from, pos) + value; from = end; pos = end; replaced = true; continue; }
        }
        pos += startToken.length;
    }
    return replaced ? out + text.slice(from) : '';
}
function jsonString(ctx, rule) {
    if (!rule) return null;
    const { parts, type } = splitRule(rule, ['&&', '||']);
    if (parts.length === 1) {
        const inner = innerRule(rule, '{$.', r => jsonString(ctx, r));
        if (inner) return inner;
        try { const v = jsonRead(ctx, rule); return Array.isArray(v) ? v.map(jsonText).join('\n') : jsonText(v); } catch { return ''; }
    }
    const texts = [];
    for (const r of parts) { const t = jsonString(ctx, r); if (t) { texts.push(t); if (type === '||') break; } }
    return texts.join('\n');
}
function jsonStringList(ctx, rule) {
    if (!rule) return [];
    const { parts, type } = splitRule(rule, ['&&', '||', '%%']);
    if (parts.length === 1) {
        const inner = innerRule(rule, '{$.', r => jsonString(ctx, r));
        if (inner) return [inner];
        try { const v = jsonRead(ctx, rule); return Array.isArray(v) ? v.map(jsonText) : [jsonText(v)]; } catch { return []; }
    }
    const lists = [];
    for (const r of parts) { const l = jsonStringList(ctx, r); if (l.length) { lists.push(l); if (type === '||') break; } }
    return combine(lists, type);
}
function jsonList(ctx, rule) {
    if (!rule) return [];
    const { parts, type } = splitRule(rule, ['&&', '||', '%%']);
    if (parts.length === 1) {
        try { const v = jsonRead(ctx, parts[0]); return Array.isArray(v) ? v.filter(x => x != null) : []; } catch { return []; }
    }
    const lists = [];
    for (const r of parts) { const l = jsonList(ctx, r); if (l.length) { lists.push(l); if (type === '||') break; } }
    return combine(lists, type);
}

// --- XPath ---------------------------------------------------------------------------------
function xpathItems(ctx, rule) {
    const { parts, type } = splitRule(rule, ['&&', '||', '%%']);
    if (parts.length === 1) { const v = XPath.select(ctx, rule); return Array.isArray(v) ? v : [v]; }
    const lists = [];
    for (const r of parts) { const l = xpathItems(ctx, r); if (l.length) { lists.push(l); if (type === '||') break; } }
    return combine(lists, type);
}
function xpathString(ctx, rule) {
    const { parts, type } = splitRule(rule, ['&&', '||']);
    if (parts.length === 1) { const v = XPath.select(ctx, rule); return Array.isArray(v) ? v.map(XPath.asString).join('\n') : String(v ?? ''); }
    const texts = [];
    for (const r of parts) { const t = xpathString(ctx, r); if (t) { texts.push(t); if (type === '||') break; } }
    return texts.join('\n');
}

// --- Regex (AnalyzeByRegex) -------------------------------------------------------------------
function regexElements(text, regs, index = 0) {
    const regex = javaRegex(regs[index], 'g');
    if (!regex) return [];
    const all = [...String(text).matchAll(regex)];
    if (!all.length) return [];
    if (index + 1 === regs.length) return all.map(m => Array.from(m, g => g ?? ''));
    return regexElements(all.map(m => m[0]).join(''), regs, index + 1);
}
function regexElement(text, regs, index = 0) {
    const regex = javaRegex(regs[index], 'g');
    if (!regex) return null;
    const all = [...String(text).matchAll(regex)];
    if (!all.length) return null;
    if (index + 1 === regs.length) return Array.from(all[0], g => g ?? '');
    return regexElement(all.map(m => m[0]).join(''), regs, index + 1);
}

// --- HtmlFormatter ---------------------------------------------------------------------------
const imgPattern = /<img[^>]*\ssrc\s*=\s*['"]([^'"{>]*\{(?:[^{}]|\{[^}>]+\})+\})['"][^>]*>|<img[^>]*\sdata-(?:src|original|srcset)\s*=\s*['"]([^'">]+)['"][^>]*>|<img[^>]*\ssrc\s*=\s*"([^">]+)"[^>]*>|<img[^>]*\s(?:data-[^=>]*|src)=\s*['"]([^'">]*)['"][^>]*>/gi;
function formatText(html, otherRegex, indent) {
    return String(html ?? '').replace(/\\r\\n/g, '\n').replace(/\\n/g, '\n').replace(/\\r/g, '\n')
        .replace(/(&nbsp;)+/g, ' ').replace(/(&ensp;|&emsp;)/g, ' ').replace(/(&thinsp;|&zwnj;|&zwj;| |‌|‍)/g, '')
        .replace(/<\/?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>/gi, '\n').replace(/<!--[^>]*-->/g, '').replace(otherRegex, '')
        .replace(/\s*\n+\s*/g, '\n' + indent).replace(/^[\n\s]+/, indent).replace(/[\n\s]+$/, '');
}
const formatIntro = html => formatText(html, /<\/?[a-zA-Z]+(?=[ >])[^<>]*>/g, '');
function formatKeepImg(html, base) {
    const keep = formatText(html, /<\/?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>/g, '　　');
    return keep.replace(imgPattern, (all, g1, g2, g3, g4) => {
        let param = '', src;
        if (g1) { const [u, o] = splitOptions(g1); src = u; if (o != null) param = ',' + o; } else src = g2 ?? g3 ?? g4 ?? '';
        return `<img src="${absoluteURL(base, src) + param}">`;
    });
}
const formatBookName = name => String(name ?? '').replace(/\s+作\s*者.*|\s+\S+\s+著/g, '').trim();
const formatBookAuthor = author => String(author ?? '').replace(/^\s*作\s*者[:：\s]+|\s+著/g, '').trim();
function wordCountFormat(wc) {
    const s = String(wc ?? '').trim();
    if (!/^\d+$/.test(s)) return s;
    const n = parseInt(s);
    if (n <= 0) return '';
    return n > 10000 ? (n / 10000).toFixed(1).replace(/\.0$/, '') + '万字' : n + '字';
}
const isTrue = s => { const t = String(s ?? '').trim(); return !!t && t !== 'null' && !/^(false|no|not|0)$/i.test(t); };

// --- AnalyzeRule -----------------------------------------------------------------------------
const runner = new Function('__scope', '__code', 'with (__scope) { return eval(__code); }');
// Rhino gives a script the value of its last expression statement even when a statement after it (an `if` not
// taken, a loop) has none: `c = java.getElement(path); if (!c.length) {...}` answers c. ES2015 engines answer
// undefined. So a script that ends in such a statement runs in two parts, and the second's value wins only when
// it has one. Finds where that last compound statement starts at the top level, or -1.
function trailingCompound(code) {
    const n = code.length;
    let depth = 0, i = 0, last = -1, prev = '', start = true;
    const skipQuoted = q => { i++; while (i < n && code[i] !== q) { if (code[i] === '\\') i++; i++; } i++; };
    while (i < n) {
        const c = code[i];
        if (c === '/' && code[i + 1] === '/') { const e = code.indexOf('\n', i); i = e < 0 ? n : e; continue; }
        if (c === '/' && code[i + 1] === '*') { const e = code.indexOf('*/', i + 2); i = e < 0 ? n : e + 2; continue; }
        if (/\s/.test(c)) { if (c === '\n' && depth === 0 && prev && !/[(,=:[!&|?+\-*%<>~^.]/.test(prev)) start = true; i++; continue; }
        const statementStart = start && depth === 0;
        start = false;
        if (c === '"' || c === "'") { if (statementStart) last = -1; skipQuoted(c); prev = 'v'; continue; }
        if (c === '`') {
            if (statementStart) last = -1;
            i++;
            while (i < n && code[i] !== '`') {
                if (code[i] === '\\') { i += 2; continue; }
                if (code[i] === '$' && code[i + 1] === '{') {
                    let d = 1; i += 2;
                    while (i < n && d > 0) { const q = code[i]; if (q === '{') d++; else if (q === '}') d--; else if (q === '"' || q === "'" || q === '`') { skipQuoted(q); continue; } i++; }
                    continue;
                }
                i++;
            }
            i++; prev = 'v'; continue;
        }
        if (c === '/' && (!prev || prev === 'kw' || /[(,=:[!&|?{};+\-*%<>~^}]/.test(prev))) {
            if (statementStart) last = -1;
            i++;
            let inClass = false;
            while (i < n) { const d = code[i]; if (d === '\\') { i += 2; continue; } if (d === '[') inClass = true; else if (d === ']') inClass = false; else if ((d === '/' && !inClass) || d === '\n') break; i++; }
            i++; while (i < n && /[a-z]/i.test(code[i])) i++;
            prev = 'v'; continue;
        }
        if (/[A-Za-z_$]/.test(c)) {
            let j = i; while (j < n && /[\w$]/.test(code[j])) j++;
            const word = code.slice(i, j);
            if (statementStart) { if (/^(if|for|while|try|switch)$/.test(word)) last = i; else if (!/^(else|catch|finally)$/.test(word)) last = -1; }
            prev = /^(return|typeof|instanceof|in|of|new|delete|void|throw|case|do|else|yield|await)$/.test(word) ? 'kw' : 'v';
            i = j; continue;
        }
        if (statementStart && c !== ';' && c !== '}') last = -1;
        if (c === '(' || c === '[' || c === '{') depth++;
        else if (c === ')' || c === ']' || c === '}') { depth = Math.max(0, depth - 1); if (c === '}' && depth === 0) start = true; }
        else if (c === ';' && depth === 0) start = true;
        prev = c; i++;
    }
    return last;
}
const rhinoRunner = new Function('__scope', '__head', '__tail', 'with (__scope) { var __headValue = eval(__head); var __tailValue = eval(__tail); return __tailValue === undefined ? __headValue : __tailValue; }');
function runRhino(scope, code) {
    const at = trailingCompound(code);
    if (at <= 0 || !code.slice(0, at).trim()) return runner(scope, code);
    // The two parts share what the first declares: its top-level let/const become var.
    const head = code.slice(0, at).replace(/(^|[;\n]\s*)(let|const)(\s+[A-Za-z_$])/g, '$1var$3');
    return rhinoRunner(scope, head, code.slice(at));
}
// Scripts parse what a JSON rule already gave them (`data.books[*]\n@js:JSON.parse(result)`), or a response:
// Rhino's JSON.parse would have read a Java value's JSON text, so the value itself comes back.
const nativeParse = JSON.parse;
JSON.parse = function (text, reviver) {
    if (text instanceof StrResponse) text = text.body();
    else if (text !== null && typeof text === 'object' && !(text instanceof String)) return text;
    return nativeParse.call(JSON, text, reviver);
};
/// `@put:{key: rule, ...}`, which Legado reads with Gson's lenient parser: keys and values may go unquoted.
function putMap(text) {
    try { const v = JSON.parse(text); if (v && typeof v === 'object') return v; } catch { }
    const map = {};
    const body = String(text).trim().replace(/^\{|\}$/g, '');
    for (const m of body.matchAll(/\s*("[^"]*"|'[^']*'|[^:,]+?)\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^,]*)\s*(?:,|$)/g)) {
        const unquote = s => /^(["']).*\1$/s.test(s) ? s.slice(1, -1) : s.trim();
        if (m[1].trim()) map[unquote(m[1].trim())] = unquote(m[2].trim());
    }
    return map;
}
class SourceRule {
    constructor(an, ruleStr, mode = 'Default') {
        this.an = an; this.mode = mode; this.replaceRegex = ''; this.replacement = ''; this.replaceFirst = false;
        this.putMap = {}; this.params = []; this.types = [];
        let rule;
        if (mode === 'Js' || mode === 'Regex' || mode === 'WebJs') rule = ruleStr;
        else if (/^@CSS:/i.test(ruleStr)) { this.mode = 'Default'; rule = ruleStr; }
        else if (ruleStr.startsWith('@@')) { this.mode = 'Default'; rule = ruleStr.slice(2); }
        else if (/^@XPath:/i.test(ruleStr)) { this.mode = 'XPath'; rule = ruleStr.slice(7); }
        else if (/^@Json:/i.test(ruleStr)) { this.mode = 'Json'; rule = ruleStr.slice(6); }
        else if (an.isJSON || ruleStr.startsWith('$.') || ruleStr.startsWith('$[')) { this.mode = 'Json'; rule = ruleStr; }
        else if (ruleStr.startsWith('/')) { this.mode = 'XPath'; rule = ruleStr; }
        else rule = ruleStr;
        // @put:{key: rule}
        rule = rule.replace(/@put:(\{[^}]+?\})/gi, (_, json) => { Object.assign(this.putMap, putMap(json)); return ''; });
        const evalRe = /@get:\{[^}]+?\}|\{\{[\s\S]*?\}\}/gi;
        let start = 0, m, first = true;
        while ((m = evalRe.exec(rule))) {
            if (first) {
                first = false;
                const before = rule.slice(0, m.index);
                if (this.mode !== 'Js' && this.mode !== 'Regex' && (m.index === 0 || !before.includes('##'))) this.mode = 'Regex';
            }
            if (m.index > start) this.splitRegex(rule.slice(start, m.index));
            const t = m[0];
            if (/^@get:/i.test(t)) { this.types.push(-2); this.params.push(t.slice(6, -1)); }
            else if (t.startsWith('{{')) { this.types.push(-1); this.params.push(t.slice(2, -2)); }
            else this.splitRegex(t);
            start = m.index + t.length;
        }
        if (rule.length > start) this.splitRegex(rule.slice(start));
        this.rule = rule;
    }
    splitRegex(ruleStr) {
        const head = ruleStr.split('##')[0];
        const re = /\$\d{1,2}/g;
        let start = 0, m;
        while ((m = re.exec(head))) {
            if (this.mode !== 'Js' && this.mode !== 'Regex') this.mode = 'Regex';
            if (m.index > start) { this.types.push(0); this.params.push(ruleStr.slice(start, m.index)); }
            this.types.push(parseInt(m[0].slice(1))); this.params.push(m[0]);
            start = m.index + m[0].length;
        }
        if (ruleStr.length > start) { this.types.push(0); this.params.push(ruleStr.slice(start)); }
    }
    makeUpRule(result) {
        if (this.params.length) {
            let info = '';
            for (let i = this.params.length - 1; i >= 0; i--) {
                const type = this.types[i], param = this.params[i];
                if (type > 0) {
                    if (Array.isArray(result)) { if (result.length > type && result[type] != null) info = String(result[type]) + info; }
                    else info = param + info;
                } else if (type === -1) {
                    if (/^(@|\$\.|\$\[|\/\/)/.test(param)) info = this.an.getString([new SourceRule(this.an, param)]) + info;
                    else { const v = this.an.evalJS(param, result); if (v != null) info = jsString(v) + info; }
                } else if (type === -2) info = this.an.get(param) + info;
                else info = param + info;
            }
            this.rule = info;
        }
        const parts = this.rule.split('##');
        this.rule = parts[0].trim();
        this.replaceRegex = parts[1] ?? ''; this.replacement = parts[2] ?? ''; this.replaceFirst = parts.length > 3;
    }
}

const isPlainObject = v => v != null && typeof v === 'object' && !Array.isArray(v) && !isNode(v) && !(v instanceof StrResponse);
class Analyzer {
    constructor({ ruleData = null, book = null, chapter = null, nextChapterUrl = null } = {}) {
        this.ruleData = ruleData ?? book; this.chapter = chapter; this.nextChapterUrl = nextChapterUrl;
        this.content = null; this.baseUrl = null; this.redirectUrl = null; this.isJSON = false; this.isRegex = false;
        this.locals = {}; this.docCache = null; this.jsonCache = null;
    }
    get book() { return this.ruleData instanceof Book ? this.ruleData : null; }
    setContent(content, baseUrl) {
        if (content == null) throw new Error('Content cannot be null');
        if (isNode(content) && (content.type === 'attribute' || content.type === 'text')) content = XPath.asString(content);
        this.content = content;
        this.isJSON = isNode(content) ? false : typeof content === 'string' ? isJsonText(content) : typeof content === 'object';
        if (baseUrl) this.baseUrl = baseUrl;
        this.docCache = null; this.jsonCache = null;
        return this;
    }
    setBaseUrl(url) { if (url) this.baseUrl = url; return this; }
    setRedirectUrl(url) { if (!isDataUrl(url)) this.redirectUrl = url; return this.redirectUrl; }
    setRuleData(data) { this.ruleData = data; return this; }
    setChapter(chapter) { this.chapter = chapter; return this; }

    doc(o) {
        if (isNode(o)) return o;
        if (o === this.content) { if (!this.docCache) this.docCache = parseDocument(typeof o === 'string' ? o : jsString(o)); return this.docCache; }
        return parseDocument(typeof o === 'string' ? o : Array.isArray(o) ? o.join('\n') : jsString(o));
    }
    json(o) {
        if (typeof o !== 'string') return o;
        if (o === this.content) { if (this.jsonCache === null) this.jsonCache = lenientJSON(o.trim()) ?? {}; return this.jsonCache; }
        return lenientJSON(o.trim()) ?? {};
    }
    xnode(o) { return isNode(o) ? o : this.doc(o); }

    splitSourceRule(ruleStr, allInOne = false) {
        if (!ruleStr) return [];
        ruleStr = String(ruleStr);
        const list = [];
        let mode = 'Default', start = 0;
        if (allInOne && ruleStr.startsWith(':')) { mode = 'Regex'; this.isRegex = true; start = 1; }
        else if (this.isRegex) mode = 'Regex';
        const re = /<js>([\s\S]*?)<\/js>|@js:([\s\S]*)|@webjs:([\s\S]{5,})/gi;
        let m;
        while ((m = re.exec(ruleStr))) {
            if (m.index > start) { const t = ruleStr.slice(start, m.index).trim(); if (t) list.push(new SourceRule(this, t, mode)); }
            list.push(m[3] != null ? new SourceRule(this, m[3], 'WebJs') : new SourceRule(this, m[2] ?? m[1], 'Js'));
            start = m.index + m[0].length;
        }
        if (ruleStr.length > start) { const t = ruleStr.slice(start).trim(); if (t) list.push(new SourceRule(this, t, mode)); }
        return list;
    }
    putRule(map) { for (const [k, v] of Object.entries(map)) this.put(k, this.getString(String(v))); }
    replaceRegexIn(text, rule) {
        if (!rule.replaceRegex) return text;
        const regex = javaRegex(rule.replaceRegex, rule.replaceFirst ? '' : 'g');
        const replacement = javaReplacement(rule.replacement);
        if (rule.replaceFirst) {
            if (!regex) return rule.replacement;
            const m = regex.exec(text);
            return m ? m[0].replace(regex, replacement) : '';
        }
        if (regex) return String(text).replace(regex, replacement);
        return String(text).split(rule.replaceRegex).join(rule.replacement);
    }
    webJs() { fail('This source needs a web view (@webjs), which Yingxia does not have.'); }

    getStringList(rule, mContent, isUrl = false) {
        if (!rule || (Array.isArray(rule) && !rule.length)) return null;
        const ruleList = typeof rule === 'string' ? this.splitSourceRule(rule) : rule;
        let result = null;
        const content = mContent ?? this.content;
        if (content != null && ruleList.length) {
            result = content;
            for (const sr of ruleList) {
                this.putRule(sr.putMap);
                sr.makeUpRule(result);
                if (result == null) continue;
                const r = sr.rule;
                if (r) {
                    switch (sr.mode) {
                        case 'Js': result = this.evalJS(r, result); break;
                        case 'WebJs': this.webJs(); break;
                        case 'Json': result = jsonStringList(this.json(result), r); break;
                        case 'XPath': result = xpathItems(this.xnode(result), r).map(XPath.asString); break;
                        case 'Default': result = isPlainObject(result) && sr.params.length <= 1 ? result[r] : jsoupStringList(this.doc(result), r, this.redirectUrl ?? this.baseUrl); break;
                        default: result = r;
                    }
                }
                if (sr.replaceRegex && Array.isArray(result)) result = result.map(item => this.replaceRegexIn(jsString(item), sr));
                else if (sr.replaceRegex) result = this.replaceRegexIn(jsString(result), sr);
            }
        }
        if (result == null) return null;
        if (typeof result === 'string') result = result.split('\n');
        if (!Array.isArray(result)) result = [result];
        if (isUrl) {
            const urls = [];
            for (const u of result) { const abs = absoluteURL(this.redirectUrl ?? this.baseUrl, jsString(u)); if (abs && !urls.includes(abs)) urls.push(abs); }
            return urls;
        }
        return result.map(item => isNode(item) ? outerHTML(item) : jsString(item));
    }

    getString(rule, mContent, isUrl = false, unescape = true) {
        if (!rule || (Array.isArray(rule) && !rule.length)) return '';
        const ruleList = typeof rule === 'string' ? this.splitSourceRule(rule) : rule;
        let result = null;
        const content = mContent ?? this.content;
        if (content != null && ruleList.length) {
            result = content;
            for (const sr of ruleList) {
                this.putRule(sr.putMap);
                sr.makeUpRule(result);
                if (result == null) continue;
                const r = sr.rule;
                if (r.trim() || !sr.replaceRegex) {
                    switch (sr.mode) {
                        case 'Js': result = this.evalJS(r, result); break;
                        case 'WebJs': this.webJs(); break;
                        case 'Json': result = jsonString(this.json(result), r); break;
                        case 'XPath': result = xpathString(this.xnode(result), r); break;
                        case 'Default': {
                            if (isPlainObject(result) && sr.params.length <= 1) { result = result[r]; break; }
                            const list = jsoupStringList(this.doc(result), r, this.redirectUrl ?? this.baseUrl);
                            result = isUrl ? (list[0] ?? '') : list.length === 0 ? null : list.length === 1 ? list[0] : list.join('\n');
                            break;
                        }
                        default: result = r;
                    }
                }
                if (result != null && sr.replaceRegex) result = this.replaceRegexIn(jsString(result), sr);
            }
        }
        if (result == null) result = '';
        let text = isNode(result) ? outerHTML(result) : jsString(result);
        if (unescape && text.includes('&')) text = unescapeHtml(text);
        if (isUrl) return text.trim() ? absoluteURL(this.redirectUrl ?? this.baseUrl, text) : (this.baseUrl ?? '');
        return text;
    }

    getElement(rule) {
        if (!rule) return null;
        let result = null;
        const ruleList = this.splitSourceRule(String(rule), true);
        if (this.content != null && ruleList.length) {
            result = this.content;
            for (const sr of ruleList) {
                this.putRule(sr.putMap);
                sr.makeUpRule(result);
                if (result == null) continue;
                const r = sr.rule;
                switch (sr.mode) {
                    case 'Regex': result = regexElement(jsString(result), r.split('&&').filter(s => s.trim())); break;
                    case 'Js': result = this.evalJS(r, result); break;
                    case 'WebJs': this.webJs(); break;
                    case 'Json': try { result = jsonRead(this.json(result), r); } catch { result = null; } break;
                    case 'XPath': result = xpathItems(this.xnode(result), r); break;
                    default: result = jsoupElements(this.doc(result), r);
                }
                if (sr.replaceRegex) result = this.replaceRegexIn(jsString(result), sr);
            }
        }
        return result;
    }

    getElements(rule) {
        let result = null;
        const ruleList = this.splitSourceRule(String(rule ?? ''), true);
        if (this.content != null && ruleList.length) {
            result = this.content;
            for (const sr of ruleList) {
                this.putRule(sr.putMap);
                if (result == null) continue;
                const r = sr.rule;
                switch (sr.mode) {
                    case 'Regex': result = regexElements(jsString(result), r.split('&&').filter(s => s.trim())); break;
                    case 'Js': result = this.evalJS(r, result); break;
                    case 'WebJs': this.webJs(); break;
                    case 'Json': result = jsonList(this.json(result), r); break;
                    case 'XPath': result = xpathItems(this.xnode(result), r).filter(x => typeof x !== 'string' || x); break;
                    default: result = jsoupElements(this.doc(result), r);
                }
            }
        }
        return Array.isArray(result) ? result.filter(x => x != null) : [];
    }

    put(key, value) {
        const v = value == null ? '' : String(value);
        if (this.chapter) this.chapter.putVariable(key, v);
        else if (this.ruleData) this.ruleData.putVariable(key, v);
        else source.put(key, v);
        return v;
    }
    get(key) {
        if (this.locals[key] != null && typeof this.locals[key] !== 'object') return String(this.locals[key]);
        if (key === 'bookName' && this.book) return this.book.name;
        if (key === 'title' && this.chapter) return this.chapter.title;
        return (this.chapter?.getVariable(key) || '') || (this.ruleData?.getVariable(key) || '') || source.get(key) || '';
    }

    evalJS(code, result) {
        const scope = {
            java: this, cookie, cache, source, book: this.book, result, baseUrl: this.baseUrl, chapter: this.chapter, title: this.chapter?.title ?? null,
            src: this.content, nextChapterUrl: this.nextChapterUrl, rssArticle: null, fromBookInfo: false,
        };
        for (const [k, v] of Object.entries(this.locals)) if (v != null) scope[k] = v;
        // Script functions from jsLib see the caller's bindings, as with Rhino's shared scope.
        Object.assign(globalThis, scope);
        try { return runRhino(scope, rhinoSyntax(String(code))); }
        catch (error) {
            if (error && typeof error === 'object' && !(error instanceof LegadoError) && !error.__logged) { error.__logged = true; log('script error:', String(error.message ?? error), 'in:', String(code).trim().slice(0, 160)); }
            throw error;
        }
    }
}

// JsExtensions: the `java` object scripts call.
const symmetric = (transformation, key, iv) => new SymmetricCrypto(transformation, key, iv);
Object.assign(Analyzer.prototype, {
    ajax(url) {
        const address = Array.isArray(url) ? String(url[0]) : String(url);
        try { return perform(buildRequest(address, { baseUrl: this.baseUrl ?? S.bookSourceUrl, ruleData: this.ruleData, chapter: this.chapter })).body(); }
        catch (error) { log(`ajax(${address}) failed: ${error?.message ?? error}`); return String(error?.message ?? error); }
    },
    ajaxAll(urls) { return Array.from(urls ?? [], u => { try { return this.connect(String(u)); } catch (error) { return new StrResponse(String(u), String(error?.message ?? error), 500); } }); },
    connect(url, header) {
        const request = buildRequest(String(url), { baseUrl: this.baseUrl ?? S.bookSourceUrl, ruleData: this.ruleData, chapter: this.chapter });
        const extra = header ? lenientJSON(String(header)) : null;
        if (extra && typeof extra === 'object') for (const [k, v] of Object.entries(extra)) request.headers[k] = String(v);
        try { return perform(request); } catch (error) { return new StrResponse(request.url, String(error?.message ?? error), 500); }
    },
    get(urlOrKey, headers) {
        if (headers === undefined) return Analyzer.prototype.getVar.call(this, urlOrKey);
        return jsoupRequest('GET', urlOrKey, null, headers);
    },
    post(url, body, headers) { return jsoupRequest('POST', url, body, headers); },
    head(url, headers) { return jsoupRequest('HEAD', url, null, headers); },
    getVar(key) {
        const k = String(key);
        if (this.locals[k] != null && typeof this.locals[k] !== 'object') return String(this.locals[k]);
        if (k === 'bookName' && this.book) return this.book.name;
        if (k === 'title' && this.chapter) return this.chapter.title;
        return (this.chapter?.getVariable(k) || '') || (this.ruleData?.getVariable(k) || '') || source.get(k) || '';
    },
    getSource() { return source; }, getTag() { return S.bookSourceName; },
    base64Decode(text, charsetOrFlags) { return decodeBytes(bytesFromBase64(String(text ?? '').replace(/-/g, '+').replace(/_/g, '/')), typeof charsetOrFlags === 'string' ? charsetOrFlags : 'utf-8'); },
    base64DecodeToByteArray(text) { return bytesFromBase64(String(text ?? '').replace(/-/g, '+').replace(/_/g, '/')); },
    base64Encode(text, flags) { const b = base64FromBytes(toBytes(String(text ?? ''))); return flags & 8 ? b.replace(/\+/g, '-').replace(/\//g, '_') : b; },
    strToBytes(text, charset = 'utf-8') { return encodeText(String(text ?? ''), charset); },
    bytesToStr(bytes, charset = 'utf-8') { return decodeBytes(toBytes(bytes), charset); },
    hexDecodeToByteArray(hex) { return bytesFromHex(hex); },
    hexDecodeToString(hex) { return decodeBytes(bytesFromHex(hex), 'utf-8'); },
    hexEncodeToString(text) { return hexFromBytes(toBytes(String(text ?? ''))); },
    md5Encode(text) { return host('md5', String(text ?? '')); },
    md5Encode16(text) { return host('md5', String(text ?? '')).slice(8, 24); },
    encodeURI(text, enc = 'UTF-8') { return formEncode(String(text ?? ''), enc); },
    timeFormat(time) { return formatDate(Number(time), 'yyyy/MM/dd HH:mm', null); },
    timeFormatUTC(time, format, sh) { return formatDate(Number(time), String(format), Number(sh) || 0); },
    htmlFormat(text, base) { return formatKeepImg(String(text ?? ''), base ?? this.redirectUrl); },
    t2s(text) { try { return host('novel.convert', JSON.stringify({ text: String(text ?? ''), to: 'hans' })) ?? String(text); } catch { return String(text ?? ''); } },
    s2t(text) { try { return host('novel.convert', JSON.stringify({ text: String(text ?? ''), to: 'hant' })) ?? String(text); } catch { return String(text ?? ''); } },
    log(message) { log(isNode(message) ? outerHTML(message) : jsString(message)); return message; },
    logType(value) { log(value == null ? 'null' : Array.isArray(value) ? 'Array' : typeof value); },
    toast(message) { log('toast', jsString(message)); }, longToast(message) { log('toast', jsString(message)); },
    randomUUID() { const h = Array.from({ length: 32 }, () => Math.floor(Math.random() * 16).toString(16)).join(''); return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20)}`; },
    androidId() { let id = store.get('device', 'androidId'); if (!id) { id = Array.from({ length: 16 }, () => Math.floor(Math.random() * 16).toString(16)).join(''); store.set('device', 'androidId', id); } return id; },
    getCookie(tag, key) { return key ? cookie.getKey(tag, key) : cookie.getCookie(tag); },
    getWebViewUA() { return UA; }, getUserAgent() { return UA; },
    toNumChapter(text) { return toNumChapter(text); },
    toURL(url, base) { return jsURL(String(url), base); },
    importScript(path) {
        const p = String(path);
        if (/^https?:/i.test(p)) return this.cacheFile(p);
        return '';
    },
    cacheFile(url, saveTime = 0) {
        const key = 'cacheFile:' + host('md5', String(url));
        const kept = cache.get(key);
        if (kept) return kept;
        const text = perform(buildRequest(String(url), { baseUrl: S.bookSourceUrl })).body();
        if (text) cache.put(key, text, saveTime);
        return text;
    },
    downloadFile() { return ''; }, readFile() { return null; }, readTxtFile() { return ''; }, getFile() { return null; }, deleteFile() { return false; },
    getZipStringContent() { return ''; }, getTxtInFolder() { return ''; },
    webView(html, url, js) { return webView({ html: html == null ? null : String(html), url: url == null ? null : absoluteURL(this.baseUrl ?? S.bookSourceUrl, String(url)), js: js == null ? null : String(js) }).content; },
    webViewGetSource() { fail('This source needs a web view, which Yingxia does not have.'); },
    webViewGetOverrideUrl() { fail('This source needs a web view, which Yingxia does not have.'); },
    // Legado shows its browser for the reader to pass a check or sign in; here an off-screen one loads the page,
    // which gets past checks a browser passes by itself, and hands its cookies to the source.
    startBrowser(url) { webView({ url: absoluteURL(this.baseUrl ?? S.bookSourceUrl, String(url)), challenge: true }); },
    startBrowserAwait(url) { const page = webView({ url: absoluteURL(this.baseUrl ?? S.bookSourceUrl, String(url)), challenge: true }); return new StrResponse(page.url, page.content, 200, {}); },
    showBrowser() { fail('This source needs a browser, which Yingxia does not offer.'); }, openUrl() { }, openVideoPlayer() { },
    getVerificationCode() { fail('This source needs a verification code, which Yingxia cannot show.'); },
    queryTTF() { return null; }, queryBase64TTF() { return null; }, replaceFont(text) { return text; },
    getReadBookConfig() { return '{}'; }, getReadBookConfigMap() { return {}; }, getThemeMode() { return 'day'; }, getThemeConfig() { return '{}'; }, getThemeConfigMap() { return {}; },
    refreshBookInfo() { }, refreshBookToc() { }, refreshContent() { }, cacheContent() { }, tick() { }, reGetBook() { }, refreshTocUrl() { },
    // JsEncodeUtils
    createSymmetricCrypto: symmetric,
    createAsymmetricCrypto() { fail('RSA is not supported for book sources yet.'); },
    createSign() { fail('Signatures are not supported for book sources yet.'); },
    aesDecodeToString(data, key, transformation, iv) { return symmetric(transformation, key, iv).decryptStr(data); },
    aesDecodeToByteArray(data, key, transformation, iv) { return symmetric(transformation, key, iv).decrypt(data); },
    aesBase64DecodeToString(data, key, transformation, iv) { return symmetric(transformation, key, iv).decryptStr(data); },
    aesBase64DecodeToByteArray(data, key, transformation, iv) { return symmetric(transformation, key, iv).decrypt(data); },
    aesDecodeArgsBase64Str(data, key, mode, padding, iv) { return symmetric(`AES/${mode}/${padding}`, bytesFromBase64(key), bytesFromBase64(iv)).decryptStr(data); },
    aesEncodeToString(data, key, transformation, iv) { return decodeBytes(symmetric(transformation, key, iv).encrypt(data), 'utf-8'); },
    aesEncodeToByteArray(data, key, transformation, iv) { return symmetric(transformation, key, iv).encrypt(data); },
    aesEncodeToBase64String(data, key, transformation, iv) { return symmetric(transformation, key, iv).encryptBase64(data); },
    aesEncodeToBase64ByteArray(data, key, transformation, iv) { return toBytes(symmetric(transformation, key, iv).encryptBase64(data)); },
    aesEncodeArgsBase64Str(data, key, mode, padding, iv) { return symmetric(`AES/${mode}/${padding}`, bytesFromBase64(key), bytesFromBase64(iv)).encryptBase64(data); },
    desDecodeToString(data, key, transformation, iv) { return symmetric(transformation, key, iv).decryptStr(data); },
    desBase64DecodeToString(data, key, transformation, iv) { return symmetric(transformation, key, iv).decryptStr(data); },
    desEncodeToString(data, key, transformation, iv) { return decodeBytes(symmetric(transformation, key, iv).encrypt(data), 'utf-8'); },
    desEncodeToBase64String(data, key, transformation, iv) { return symmetric(transformation, key, iv).encryptBase64(data); },
    tripleDESDecodeStr(data, key, mode, padding, iv) { return symmetric(`DESede/${mode}/${padding}`, key, iv).decryptStr(data); },
    tripleDESDecodeArgsBase64Str(data, key, mode, padding, iv) { return symmetric(`DESede/${mode}/${padding}`, bytesFromBase64(key), bytesFromBase64(iv)).decryptStr(data); },
    tripleDESEncodeBase64Str(data, key, mode, padding, iv) { return symmetric(`DESede/${mode}/${padding}`, key, iv).encryptBase64(data); },
    tripleDESEncodeArgsBase64Str(data, key, mode, padding, iv) { return symmetric(`DESede/${mode}/${padding}`, bytesFromBase64(key), bytesFromBase64(iv)).encryptBase64(data); },
    digestHex(data, algorithm) { return digest(data, algorithm, 'hex'); },
    digestBase64Str(data, algorithm) { return digest(data, algorithm, 'base64'); },
    HMacHex(data, algorithm, key) { return hmac(data, algorithm, key, 'hex'); },
    HMacBase64(data, algorithm, key) { return hmac(data, algorithm, key, 'base64'); },
});
// java.get(key) reads a variable; java.get(url, headers) is a request.
Analyzer.prototype.get = function (a, b) { return b === undefined ? this.getVar(a) : jsoupRequest('GET', a, null, b); };

function jsoupRequest(method, url, body, headers) {
    const map = typeof headers === 'string' ? lenientJSON(headers) ?? {} : headers ?? {};
    const hs = {};
    for (const [k, v] of Object.entries(map)) hs[k] = String(v);
    if (body != null && !hasHeader(hs, 'Content-Type')) hs['Content-Type'] = isJsonText(body) ? 'application/json; charset=UTF-8' : 'application/x-www-form-urlencoded';
    const answer = sendHTTP({ url: String(url), method, headers: hs, body: body == null ? null : String(body) });
    return new JsoupResponse(answer.url || String(url), method === 'HEAD' ? '' : decodeAnswer(answer, null), answer.code ?? 0, answer.headers ?? {});
}

// --- Crypto (Hutool's SymmetricCrypto on CryptoJS, loaded the first time it's needed) -----------
function cryptoJS() {
    if (!globalThis.__cryptoJS) {
        const code = host('module', 'assets://js/lib/crypto-js.js');
        (0, eval)(code);
        globalThis.__cryptoJS = globalThis.CryptoJS;
    }
    return globalThis.__cryptoJS;
}
if (!('CryptoJS' in globalThis)) Object.defineProperty(globalThis, 'CryptoJS', { configurable: true, get() { delete globalThis.CryptoJS; return cryptoJS(); }, set(v) { Object.defineProperty(globalThis, 'CryptoJS', { value: v, writable: true, configurable: true }); } });
const toWords = bytes => { const C = cryptoJS(); const words = []; bytes.forEach((b, i) => { words[i >>> 2] |= (b & 255) << (24 - (i % 4) * 8); }); return C.lib.WordArray.create(words, bytes.length); };
const fromWords = wa => { const out = []; for (let i = 0; i < wa.sigBytes; i++) out.push((wa.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 255); return out; };
const keyBytes = k => k == null ? [] : typeof k === 'string' ? encodeText(k) : toBytes(k);
const dataBytes = data => {
    if (typeof data !== 'string') return toBytes(data);
    const s = data.trim();
    if (/^[0-9a-fA-F]+$/.test(s) && s.length % 2 === 0) return bytesFromHex(s);
    return bytesFromBase64(s.replace(/-/g, '+').replace(/_/g, '/'));
};
class SymmetricCrypto {
    constructor(transformation, key, iv) {
        const [algorithm = 'AES', mode = 'ECB', padding = 'PKCS5Padding'] = String(transformation ?? 'AES').split('/');
        this.algorithm = algorithm.toUpperCase(); this.mode = mode.toUpperCase(); this.padding = padding.toUpperCase();
        this.key = keyBytes(key); this.iv = iv == null ? null : keyBytes(iv);
    }
    config() {
        const C = cryptoJS();
        const mode = { CBC: C.mode.CBC, ECB: C.mode.ECB, CFB: C.mode.CFB, OFB: C.mode.OFB, CTR: C.mode.CTR }[this.mode] ?? C.mode.ECB;
        const padding = /NOPADDING/.test(this.padding) ? C.pad.NoPadding : /ZERO/.test(this.padding) ? C.pad.ZeroPadding : /ISO10126/.test(this.padding) ? C.pad.Iso10126 : /X923/.test(this.padding) ? C.pad.AnsiX923 : C.pad.Pkcs7;
        const cfg = { mode, padding };
        if (this.iv && this.mode !== 'ECB') cfg.iv = toWords(this.iv);
        const cipher = this.algorithm.startsWith('DESEDE') || this.algorithm === 'TRIPLEDES' ? C.TripleDES : this.algorithm.startsWith('DES') ? C.DES : C.AES;
        return { C, cipher, cfg };
    }
    decrypt(data) { const { C, cipher, cfg } = this.config(); return fromWords(cipher.decrypt(C.lib.CipherParams.create({ ciphertext: toWords(dataBytes(data)) }), toWords(this.key), cfg)); }
    decryptStr(data, charset = 'utf-8') { return decodeBytes(this.decrypt(data), charset); }
    encrypt(data) { const { cipher, cfg } = this.config(); return fromWords(cipher.encrypt(toWords(toBytes(data)), toWords(this.key), cfg).ciphertext); }
    encryptBase64(data) { return base64FromBytes(this.encrypt(data)); }
    encryptHex(data) { return hexFromBytes(this.encrypt(data)); }
    setIv(iv) { this.iv = keyBytes(iv); return this; }
}
function digest(data, algorithm, output) {
    const C = cryptoJS();
    const name = String(algorithm).toUpperCase().replace(/-/g, '');
    const fn = { MD5: C.MD5, SHA1: C.SHA1, SHA256: C.SHA256, SHA224: C.SHA224, SHA384: C.SHA384, SHA512: C.SHA512 }[name];
    if (!fn) fail('Unsupported digest ' + algorithm);
    const words = fn(toWords(toBytes(data)));
    return output === 'hex' ? words.toString(C.enc.Hex) : words.toString(C.enc.Base64);
}
function hmac(data, algorithm, key, output) {
    const C = cryptoJS();
    const name = String(algorithm).toUpperCase().replace(/^HMAC/, '').replace(/-/g, '');
    const fn = { MD5: C.HmacMD5, SHA1: C.HmacSHA1, SHA256: C.HmacSHA256, SHA224: C.HmacSHA224, SHA384: C.HmacSHA384, SHA512: C.HmacSHA512 }[name];
    if (!fn) fail('Unsupported HMAC ' + algorithm);
    const words = fn(toWords(toBytes(data)), toWords(keyBytes(key)));
    return output === 'hex' ? words.toString(C.enc.Hex) : words.toString(C.enc.Base64);
}

// --- Small helpers scripts call ----------------------------------------------------------------
function formatDate(ms, format, offsetHours) {
    const d = new Date(ms + (offsetHours != null ? offsetHours * 3600000 : -new Date(ms).getTimezoneOffset() * 60000));
    const pad = (n, w = 2) => String(n).padStart(w, '0');
    const parts = { yyyy: d.getUTCFullYear(), yy: pad(d.getUTCFullYear() % 100), MM: pad(d.getUTCMonth() + 1), dd: pad(d.getUTCDate()), HH: pad(d.getUTCHours()),
        mm: pad(d.getUTCMinutes()), ss: pad(d.getUTCSeconds()), SSS: pad(d.getUTCMilliseconds(), 3), M: d.getUTCMonth() + 1, d: d.getUTCDate(), H: d.getUTCHours() };
    return format.replace(/yyyy|yy|MM|dd|HH|mm|ss|SSS|M|d|H/g, t => String(parts[t]));
}
function jsURL(url, base) {
    const full = base ? absoluteURL(String(base), url) : url;
    const p = parseURL(full);
    const searchParams = {};
    for (const pair of (p.query ?? '').replace(/^\?/, '').split('&')) { if (!pair) continue; const i = pair.indexOf('='); const k = i < 0 ? pair : pair.slice(0, i); try { searchParams[decodeURIComponent(k)] = i < 0 ? '' : decodeURIComponent(pair.slice(i + 1)); } catch { searchParams[k] = pair.slice(i + 1); } }
    const hostPort = (p.auth ?? '').replace(/^\/\//, '');
    return { href: full, searchParams, host: hostPort, hostname: hostPort.replace(/:\d+$/, ''), port: (/:(\d+)$/.exec(hostPort) ?? [])[1] ?? '', origin: p.scheme + '//' + hostPort,
        protocol: p.scheme, pathname: p.path, search: p.query ?? '', hash: p.frag ?? '', toString() { return full; } };
}
const CN_DIGITS = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 壹: 1, 贰: 2, 叁: 3, 肆: 4, 伍: 5, 陆: 6, 柒: 7, 捌: 8, 玖: 9 };
const CN_UNITS = { 十: 10, 拾: 10, 百: 100, 佰: 100, 千: 1000, 仟: 1000, 万: 10000, 亿: 100000000 };
function chineseNumber(text) {
    let total = 0, section = 0, number = 0;
    for (const ch of text) {
        if (ch in CN_DIGITS) number = CN_DIGITS[ch];
        else if (ch in CN_UNITS) {
            const unit = CN_UNITS[ch];
            if (unit >= 10000) { section = (section + number) * unit; total += section; section = 0; }
            else section += (number || 1) * unit;
            number = 0;
        } else if (/[0-9]/.test(ch)) number = number * 10 + Number(ch);
    }
    return total + section + number;
}
function toNumChapter(text) {
    if (text == null) return null;
    return String(text).replace(/(第)([零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟0-9]+)([章节回卷集部篇])/, (_, a, n, b) => a + chineseNumber(n) + b);
}

// --- WebBook flow ------------------------------------------------------------------------------
const infoHtml = new Map(), tocHtml = new Map();
const keep = (map, key, value) => { map.set(key, value); while (map.size > 20) map.delete(map.keys().next().value); };
const ruleOf = name => (S[name] && typeof S[name] === 'object' ? S[name] : lenientJSON(S[name]) ?? {});

function analyzeBookList(response, ruleData, request, isSearch) {
    const body = response.body();
    if (body == null) fail('The site sent nothing.');
    const baseUrl = response.url();
    const an = new Analyzer({ ruleData });
    an.setContent(body, baseUrl); an.setRedirectUrl(baseUrl);
    const isRedirect = baseUrl !== request.url && baseUrl !== request.urlNoQuery;
    const list = [];
    const searchRule = ruleOf('ruleSearch'), exploreRule = ruleOf('ruleExplore');
    if (isSearch && S.bookUrlPattern && javaFullMatch(S.bookUrlPattern, baseUrl)) {
        const book = infoItem(an, request, body, baseUrl, ruleData, isRedirect);
        return book ? [book] : [];
    }
    const listRule = isSearch ? searchRule : (exploreRule.bookList ? exploreRule : searchRule);
    let ruleList = String(listRule.bookList ?? ''), reverse = false;
    if (ruleList.startsWith('-')) { reverse = true; ruleList = ruleList.slice(1); }
    if (ruleList.startsWith('+')) ruleList = ruleList.slice(1);
    const items = an.getElements(ruleList);
    if (!items.length && tracing) log('no books page:', /<title>([^<]*)/.exec(String(body))?.[1] ?? '', [...new Set(String(body).match(/class="[^"]{3,40}"/g) ?? [])].slice(0, 60).join(' '));
    if (!items.length) log(`no books: ${response.code()} ${baseUrl} ${String(body).length} chars: ${String(body).replace(/\s+/g, ' ').slice(0, 300)}`);
    // Legado reads an empty list page as a book's own page; an error page (a 404 for an unknown book) is not one.
    if (!items.length && !S.bookUrlPattern && !(response.code() >= 400)) {
        const book = infoItem(an, request, body, baseUrl, ruleData, isRedirect);
        return book ? [book] : [];
    }
    const rules = {};
    for (const field of ['name', 'bookUrl', 'author', 'coverUrl', 'intro', 'kind', 'lastChapter', 'wordCount']) rules[field] = an.splitSourceRule(listRule[field]);
    const seen = new Set();
    for (const item of items) {
        const book = searchItem(an, item, baseUrl, ruleData.variableMap, rules);
        if (!book || seen.has(book.bookUrl)) continue;
        seen.add(book.bookUrl);
        if (book.bookUrl === baseUrl) keep(infoHtml, book.bookUrl, body);
        list.push(book);
    }
    if (reverse) list.reverse();
    return list;
}
function infoItem(an, request, body, baseUrl, ruleData, isRedirect) {
    const book = new Book({ variables: ruleData.variableMap });
    book.bookUrl = isRedirect ? baseUrl : absoluteURL(request.url, request.ruleUrl);
    an.setRuleData(book);
    // A search page that lists nothing isn't a book page either: its rules failing there means no results.
    try { analyzeBookInfo(book, body, an, baseUrl, baseUrl, false); } catch (error) { if (error instanceof LegadoError) throw error; log('not a book page:', String(error?.message ?? error)); return null; }
    if (!book.name.trim()) return null;
    keep(infoHtml, book.bookUrl, body);
    return book;
}
function searchItem(an, item, baseUrl, variables, rules) {
    const book = new Book({ variables });
    an.setRuleData(book);
    an.setContent(item);
    book.name = formatBookName(an.getString(rules.name));
    if (!book.name) return null;
    book.author = formatBookAuthor(an.getString(rules.author));
    const soft = fn => { try { fn(); } catch (error) { log('field failed', String(error?.message ?? error)); } };
    soft(() => { book.kind = (an.getStringList(rules.kind) ?? []).join(','); });
    soft(() => { book.wordCount = wordCountFormat(an.getString(rules.wordCount)); });
    soft(() => { book.latestChapterTitle = an.getString(rules.lastChapter); });
    soft(() => { book.intro = formatIntro(an.getString(rules.intro)); });
    soft(() => { const cover = an.getString(rules.coverUrl); if (cover) book.coverUrl = absoluteURL(baseUrl, cover); });
    book.bookUrl = an.getString(rules.bookUrl, undefined, true);
    if (!book.bookUrl) book.bookUrl = baseUrl;
    return book;
}
function analyzeBookInfo(book, body, an, baseUrl, redirectUrl, canReName) {
    const rule = ruleOf('ruleBookInfo');
    if (rule.init && String(rule.init).trim()) { const el = an.getElement(rule.init); if (el != null) an.setContent(el); }
    const reName = canReName && !!String(rule.canReName ?? '').trim();
    const soft = fn => { try { fn(); } catch (error) { log('info field failed', String(error?.message ?? error)); } };
    soft(() => { const name = formatBookName(an.getString(rule.name)); if (name && (reName || !book.name)) book.name = name; });
    soft(() => { const author = formatBookAuthor(an.getString(rule.author)); if (author && (reName || !book.author)) book.author = author; });
    soft(() => { const kind = (an.getStringList(rule.kind) ?? []).join(','); if (kind) book.kind = kind; });
    soft(() => { const wc = wordCountFormat(an.getString(rule.wordCount)); if (wc) book.wordCount = wc; });
    soft(() => { const last = an.getString(rule.lastChapter); if (last) book.latestChapterTitle = last; });
    soft(() => {
        const intro = an.getString(rule.intro);
        if (/^\s*<(usehtml|md|useweb)>/.test(intro)) book.intro = intro.trimStart();
        else { const text = formatIntro(intro); if (text) book.intro = text; }
    });
    soft(() => { const cover = an.getString(rule.coverUrl); if (cover) book.coverUrl = absoluteURL(redirectUrl, cover); });
    book.tocUrl = an.getString(rule.tocUrl, undefined, true);
    if (!book.tocUrl) book.tocUrl = baseUrl;
    if (book.tocUrl === baseUrl) keep(tocHtml, book.tocUrl, body);
}
function bookInfo(book) {
    const kept = infoHtml.get(book.bookUrl);
    if (kept) {
        const an = new Analyzer({ ruleData: book });
        an.setContent(kept, book.bookUrl); an.setRedirectUrl(book.bookUrl);
        analyzeBookInfo(book, kept, an, book.bookUrl, book.bookUrl, true);
        return book;
    }
    const request = buildRequest(book.bookUrl, { baseUrl: S.bookSourceUrl, ruleData: book });
    const response = performChecked(request, { book });
    const an = new Analyzer({ ruleData: book });
    an.setContent(response.body(), book.bookUrl); an.setRedirectUrl(response.url());
    analyzeBookInfo(book, response.body(), an, book.bookUrl, response.url(), true);
    return book;
}

function chapterPage(book, body, baseUrl, redirectUrl, rule, listRule, getNext) {
    const an = new Analyzer({ ruleData: book });
    an.setContent(body, baseUrl); an.setRedirectUrl(redirectUrl);
    const elements = an.getElements(listRule);
    const next = [];
    if (getNext && rule.nextTocUrl) for (const url of an.getStringList(rule.nextTocUrl, undefined, true) ?? []) if (url !== redirectUrl) next.push(url);
    const chapters = [];
    if (elements.length) {
        const names = an.splitSourceRule(rule.chapterName), urls = an.splitSourceRule(rule.chapterUrl), vip = an.splitSourceRule(rule.isVip),
            pay = an.splitSourceRule(rule.isPay), time = an.splitSourceRule(rule.updateTime), volume = an.splitSourceRule(rule.isVolume);
        elements.forEach((item, index) => {
            an.setContent(item);
            const chapter = new Chapter({}, book.bookUrl, redirectUrl);
            an.setChapter(chapter);
            chapter.title = an.getString(names);
            chapter.url = an.getString(urls);
            chapter.tag = an.getString(time);
            chapter.isVolume = isTrue(an.getString(volume));
            if (!chapter.url) chapter.url = chapter.isVolume ? chapter.title + index : baseUrl;
            if (chapter.title) {
                if (isTrue(an.getString(vip))) chapter.isVip = true;
                if (isTrue(an.getString(pay))) chapter.isPay = true;
                chapters.push(chapter);
            }
        });
        an.setChapter(null);
    }
    return { chapters, next };
}
function chapterList(book) {
    const rule = ruleOf('ruleToc');
    let listRule = String(rule.chapterList ?? ''), reverse = false;
    if (listRule.startsWith('-')) { reverse = true; listRule = listRule.slice(1); }
    if (listRule.startsWith('+')) listRule = listRule.slice(1);
    let body, redirect;
    const kept = book.tocUrl === book.bookUrl ? tocHtml.get(book.tocUrl) : null;
    if (kept) { body = kept; redirect = book.tocUrl; }
    else {
        const response = performChecked(buildRequest(book.tocUrl, { baseUrl: book.bookUrl, ruleData: book }), { book });
        body = response.body(); redirect = response.url();
    }
    const visited = [redirect];
    let page = chapterPage(book, body, book.tocUrl, redirect, rule, listRule, true);
    const all = [...page.chapters];
    if (page.next.length === 1) {
        let next = page.next[0];
        while (next && !visited.includes(next) && visited.length < 300) {
            visited.push(next);
            const response = perform(buildRequest(next, { baseUrl: book.bookUrl, ruleData: book }));
            page = chapterPage(book, response.body(), next, next, rule, listRule, true);
            next = page.next[0] ?? '';
            all.push(...page.chapters);
        }
    } else if (page.next.length > 1) {
        for (const url of page.next.slice(0, 300)) {
            const response = perform(buildRequest(url, { baseUrl: book.bookUrl, ruleData: book }));
            all.push(...chapterPage(book, response.body(), url, response.url(), rule, listRule, false).chapters);
        }
    }
    if (!all.length) fail('The table of contents is empty.');
    if (!reverse) all.reverse();
    const seen = new Set(), unique = [];
    for (const c of all) { if (seen.has(c.url)) continue; seen.add(c.url); unique.push(c); }
    unique.reverse();
    unique.forEach((c, i) => { c.index = i; });
    if (rule.formatJs && String(rule.formatJs).trim()) {
        const an = new Analyzer({ ruleData: book });
        let gInt = 0;
        unique.forEach((c, i) => {
            an.locals = { index: i + 1, gInt, title: c.title };
            an.setChapter(c);
            try { const v = an.evalJS(rule.formatJs, null); gInt = globalThis.gInt ?? gInt; if (v != null) c.title = jsString(v); } catch (error) { log('formatJs', String(error?.message ?? error)); }
        });
    }
    return unique;
}

function contentPage(book, chapter, body, baseUrl, redirectUrl, rule, nextChapterUrl, getNext) {
    const an = new Analyzer({ ruleData: book, chapter, nextChapterUrl });
    an.setContent(body, baseUrl);
    const r = an.setRedirectUrl(redirectUrl);
    let content = an.getString(rule.content, undefined, false, false);
    content = formatKeepImg(content, r);
    if (content.includes('&')) content = unescapeHtml(content);
    const next = getNext && rule.nextContentUrl ? an.getStringList(rule.nextContentUrl, undefined, true) ?? [] : [];
    return { content, next, an };
}
function chapterContent(book, chapter, nextChapterUrl) {
    if (chapter.isVolume && chapter.url.startsWith(chapter.title)) return '';
    const rule = ruleOf('ruleContent');
    if (!rule.content) return chapter.url;
    const url = chapter.getAbsoluteURL();
    let body, redirect;
    const kept = url === book.bookUrl ? tocHtml.get(book.tocUrl) : null;
    if (kept) { body = kept; redirect = url; }
    else {
        const response = performChecked(buildRequest(url, { baseUrl: book.tocUrl, ruleData: book, chapter }), { book, chapter });
        body = response.body(); redirect = response.url();
    }
    const first = contentPage(book, chapter, body, url, redirect, rule, nextChapterUrl, true);
    const parts = [first.content];
    const visited = [redirect];
    const nextAbs = nextChapterUrl ? absoluteURL(redirect, nextChapterUrl) : null;
    if (first.next.length === 1) {
        let next = first.next[0];
        while (next && !visited.includes(next) && visited.length < 60) {
            if (nextAbs && absoluteURL(redirect, next) === nextAbs) break;
            visited.push(next);
            const response = perform(buildRequest(next, { baseUrl: book.tocUrl, ruleData: book, chapter }));
            const page = contentPage(book, chapter, response.body(), next, response.url(), rule, nextChapterUrl, true);
            next = page.next[0] ?? '';
            parts.push(page.content);
        }
    } else if (first.next.length > 1) {
        for (const next of first.next.slice(0, 60)) {
            const response = perform(buildRequest(next, { baseUrl: book.tocUrl, ruleData: book, chapter }));
            parts.push(contentPage(book, chapter, response.body(), next, response.url(), rule, nextChapterUrl, false).content);
        }
    }
    let text = parts.join('\n');
    if (rule.replaceRegex) {
        text = text.split(/\r?\n/).map(s => s.trim()).join('\n');
        text = first.an.getString(String(rule.replaceRegex), text);
    }
    if (rule.title && String(rule.title).trim()) {
        try {
            let title = first.an.getString(rule.title);
            if (title.trim()) { const m = /^([\s\S]*?)((?:data|https?):[\s\S]+)$/.exec(title); if (m) title = m[1] || chapter.title; chapter.title = title; }
        } catch (error) { log('title rule', String(error?.message ?? error)); }
    }
    if (!chapter.isVolume && !text.trim()) fail('The chapter has no text.');
    return text;
}

let exploreKindsKept = null;
function exploreKinds() {
    if (exploreKindsKept) return exploreKindsKept;
    let text = String(S.exploreUrl ?? '').trim();
    if (!text) return [];
    if (/^@js:/i.test(text) || /^<js>/i.test(text)) {
        const js = /^@js:/i.test(text) ? text.slice(4) : text.slice(4, text.lastIndexOf('<'));
        const an = new Analyzer({});
        an.baseUrl = S.bookSourceUrl;
        an.locals = { infoMap: {} };
        const v = an.evalJS(js, null);
        text = typeof v === 'string' ? v.trim() : v == null ? '' : safeJSON(v);
    }
    const kinds = [];
    const list = text.trim().startsWith('[') ? lenientJSON(text) : null;
    if (Array.isArray(list)) {
        for (const k of list) if (k && typeof k === 'object' && k.title != null) kinds.push({ title: String(k.title), url: k.url == null ? '' : String(k.url) });
    } else {
        for (const piece of text.split(/(?:&&|\n)+/)) {
            if (!piece.trim()) continue;
            const i = piece.indexOf('::');
            kinds.push(i < 0 ? { title: piece.trim(), url: '' } : { title: piece.slice(0, i).trim(), url: piece.slice(i + 2).trim() });
        }
    }
    exploreKindsKept = kinds;
    return kinds;
}

// --- Rhino's Java bridge: the classes sources reach through Packages, JavaImporter and org.jsoup ---------
function javaString(value, charset) {
    const text = value != null && typeof value === 'object' && (Array.isArray(value) || ArrayBuffer.isView(value)) ? decodeBytes(toBytes(value), typeof charset === 'string' ? charset : 'utf-8') : String(value ?? '');
    return new.target ? new String(text) : text;
}
Object.assign(javaString, {
    valueOf: v => String(v), join: (separator, list) => Array.from(list ?? [], String).join(String(separator)),
    format: (format, ...args) => { let i = 0; return String(format).replace(/%(\d+\$)?[-#+ 0,(]*\d*(?:\.\d+)?([sdfxXc%])/g, (all, position, type) => { if (type === '%') return '%'; const v = position ? args[parseInt(position) - 1] : args[i++]; if (type === 'd') return String(Math.trunc(Number(v))); if (type === 'x') return (Number(v) >>> 0).toString(16); if (type === 'X') return (Number(v) >>> 0).toString(16).toUpperCase(); if (type === 'f') { const p = /\.(\d+)/.exec(all); return Number(v).toFixed(p ? Number(p[1]) : 6); } return String(v); }); },
});
const javaNumber = parse => ({ parseInt: (s, radix) => parseInt(String(s), radix ?? 10), parseLong: (s, radix) => parseInt(String(s), radix ?? 10), parseDouble: s => parseFloat(s), parseFloat: s => parseFloat(s),
    valueOf: s => parse(s), toString: (n, radix) => Number(n).toString(radix ?? 10), toHexString: n => (Number(n) >>> 0).toString(16), toBinaryString: n => (Number(n) >>> 0).toString(2), MAX_VALUE: 2147483647, MIN_VALUE: -2147483648 });
class JavaMap {
    constructor(from) { this.map = new Map(); if (from instanceof JavaMap) for (const [k, v] of from.map) this.map.set(k, v); else if (from && typeof from === 'object') for (const [k, v] of Object.entries(from)) this.map.set(k, v); }
    put(k, v) { const old = this.map.get(String(k)); this.map.set(String(k), v); return old ?? null; } get(k) { return this.map.get(String(k)) ?? null; } getOrDefault(k, d) { return this.map.has(String(k)) ? this.map.get(String(k)) : d; }
    containsKey(k) { return this.map.has(String(k)); } remove(k) { const v = this.map.get(String(k)); this.map.delete(String(k)); return v ?? null; } size() { return this.map.size; } isEmpty() { return this.map.size === 0; }
    keySet() { return [...this.map.keys()]; } values() { return [...this.map.values()]; } entrySet() { return [...this.map].map(([k, v]) => ({ getKey: () => k, getValue: () => v, key: k, value: v })); }
    putAll(other) { for (const [k, v] of (other instanceof JavaMap ? other.map : Object.entries(other ?? {}))) this.map.set(String(k), v); } clear() { this.map.clear(); }
    toString() { return '{' + [...this.map].map(([k, v]) => `${k}=${v}`).join(', ') + '}'; } toJSON() { return Object.fromEntries(this.map); }
}
class JavaList extends Array {
    add(a, b) { if (b === undefined) this.push(a); else this.splice(a, 0, b); return true; } addAll(list) { this.push(...Array.from(list ?? [])); return true; }
    remove(i) { return this.splice(i, 1)[0]; } set(i, v) { const old = this[i]; this[i] = v; return old; } contains(v) { return this.includes(v); } clear() { this.length = 0; }
}
const androidBase64 = {
    DEFAULT: 0, NO_PADDING: 1, NO_WRAP: 2, CRLF: 4, URL_SAFE: 8,
    encodeToString(input, flags = 0) { let s = base64FromBytes(toBytes(input)); if (flags & 8) s = s.replace(/\+/g, '-').replace(/\//g, '_'); if (flags & 1) s = s.replace(/=+$/, ''); return s; },
    encode(input, flags = 0) { return encodeText(androidBase64.encodeToString(input, flags)); },
    decode(input, flags = 0) { const s = typeof input === 'string' ? input : latin1(toBytes(input)); return bytesFromBase64(s.replace(/-/g, '+').replace(/_/g, '/')); },
};
const javaBase64Coder = (url, pad = true) => ({
    encodeToString: b => { let s = base64FromBytes(toBytes(b)); if (url) s = s.replace(/\+/g, '-').replace(/\//g, '_'); return pad ? s : s.replace(/=+$/, ''); },
    encode(b) { return encodeText(this.encodeToString(b)); }, withoutPadding() { return javaBase64Coder(url, false); },
    decode: s => bytesFromBase64((typeof s === 'string' ? s : latin1(toBytes(s))).replace(/-/g, '+').replace(/_/g, '/')),
});
function cipher(transformation) {
    return { mode: 1, crypto: null,
        init(mode, key, iv) { this.mode = mode; this.crypto = new SymmetricCrypto(transformation, key?.keyBytes ?? key, iv?.ivBytes ?? iv ?? null); return this; },
        doFinal(data) { return this.mode === 1 ? this.crypto.encrypt(toBytes(data)) : this.crypto.decrypt(toBytes(data)); },
        getBlockSize() { return /^DES/i.test(transformation) ? 8 : 16; } };
}
const hashNames = { MD5: 'MD5', SHA1: 'SHA1', 'SHA-1': 'SHA1', SHA256: 'SHA256', 'SHA-256': 'SHA256', SHA512: 'SHA512', 'SHA-512': 'SHA512', SHA224: 'SHA224', 'SHA-224': 'SHA224', SHA384: 'SHA384', 'SHA-384': 'SHA384' };
function messageDigest(algorithm) {
    let parts = [];
    return { update(b) { parts.push(...toBytes(b)); }, reset() { parts = []; },
        digest(b) { if (b != null) parts.push(...toBytes(b)); const C = cryptoJS(); const fn = C[hashNames[String(algorithm).toUpperCase()] ?? 'MD5']; const out = fromWords(fn(toWords(parts))); parts = []; return out; } };
}
function mac(algorithm) {
    let key = [], parts = [];
    return { init(spec) { key = toBytes(spec?.keyBytes ?? spec); }, update(b) { parts.push(...toBytes(b)); },
        doFinal(b) { if (b != null) parts.push(...toBytes(b)); const C = cryptoJS(); const name = String(algorithm).toUpperCase().replace(/^HMAC/, '').replace(/-/g, ''); const fn = C['Hmac' + name] ?? C.HmacSHA256; const out = fromWords(fn(toWords(parts), toWords(key))); parts = []; return out; } };
}
function jsoupConnect(url) {
    const state = { url: String(url), method: 'GET', headers: {}, data: [], body: null };
    const builder = {
        header(k, v) { state.headers[k] = String(v); return builder; }, headers(map) { for (const [k, v] of Object.entries(map instanceof JavaMap ? map.toJSON() : map ?? {})) state.headers[k] = String(v); return builder; },
        userAgent(ua) { state.headers['User-Agent'] = String(ua); return builder; }, referrer(r) { state.headers.Referer = String(r); return builder; },
        cookie(k, v) { state.headers.Cookie = (state.headers.Cookie ? state.headers.Cookie + '; ' : '') + `${k}=${v}`; return builder; },
        cookies(map) { for (const [k, v] of Object.entries(map instanceof JavaMap ? map.toJSON() : map ?? {})) builder.cookie(k, v); return builder; },
        data(k, v) { if (v === undefined && k && typeof k === 'object') for (const [a, b] of Object.entries(k instanceof JavaMap ? k.toJSON() : k)) state.data.push([a, b]); else state.data.push([k, v]); return builder; },
        requestBody(b) { state.body = String(b); return builder; }, method(m) { state.method = String(m?.name?.() ?? m).toUpperCase(); return builder; },
        timeout() { return builder; }, ignoreContentType() { return builder; }, ignoreHttpErrors() { return builder; }, followRedirects() { return builder; }, maxBodySize() { return builder; }, validateTLSCertificates() { return builder; }, sslSocketFactory() { return builder; },
        execute() {
            const form = state.data.map(([k, v]) => formEncode(k) + '=' + formEncode(v)).join('&');
            if (state.method === 'GET' && form) return jsoupRequest('GET', state.url + (state.url.includes('?') ? '&' : '?') + form, null, state.headers);
            return jsoupRequest(state.method, state.url, state.body ?? (state.method === 'GET' ? null : form), state.headers);
        },
        get() { state.method = 'GET'; return builder.execute().parse(); }, post() { state.method = 'POST'; return builder.execute().parse(); },
    };
    return builder;
}
const javaClasses = {
    'java.lang.String': javaString, 'java.lang.Integer': javaNumber(s => parseInt(s)), 'java.lang.Long': javaNumber(s => parseInt(s)), 'java.lang.Double': javaNumber(s => parseFloat(s)),
    'java.lang.Float': javaNumber(s => parseFloat(s)), 'java.lang.Math': Math, 'java.lang.Boolean': { parseBoolean: s => String(s).toLowerCase() === 'true', valueOf: s => String(s).toLowerCase() === 'true' },
    'java.lang.System': { currentTimeMillis: () => Date.now(), nanoTime: () => Date.now() * 1e6, getProperty: () => null, lineSeparator: () => '\n' },
    'java.lang.Thread': { sleep() { }, currentThread: () => ({ getName: () => 'main', interrupt() { } }) },
    'java.lang.StringBuilder': class { constructor(s = '') { this.s = String(s); } append(v) { this.s += String(v); return this; } toString() { return this.s; } length() { return this.s.length; } reverse() { this.s = [...this.s].reverse().join(''); return this; } insert(i, v) { this.s = this.s.slice(0, i) + v + this.s.slice(i); return this; } },
    'java.lang.Character': { isDigit: c => /\d/.test(c), isLetter: c => /\p{L}/u.test(c), toChars: n => String.fromCodePoint(n) },
    'java.util.UUID': { randomUUID: () => { const id = Analyzer.prototype.randomUUID(); return { toString: () => id }; }, nameUUIDFromBytes: b => { const h = host('md5', latin1(toBytes(b))); return { toString: () => `${h.slice(0, 8)}-${h.slice(8, 12)}-3${h.slice(13, 16)}-${h.slice(16, 20)}-${h.slice(20)}` }; } },
    'java.util.Base64': { getEncoder: () => javaBase64Coder(false), getDecoder: () => javaBase64Coder(false), getUrlEncoder: () => javaBase64Coder(true), getUrlDecoder: () => javaBase64Coder(true), getMimeDecoder: () => javaBase64Coder(false), getMimeEncoder: () => javaBase64Coder(false) },
    'java.util.HashMap': JavaMap, 'java.util.LinkedHashMap': JavaMap, 'java.util.TreeMap': JavaMap, 'java.util.ArrayList': JavaList, 'java.util.LinkedList': JavaList, 'java.util.Arrays': { asList: (...items) => JavaList.from(items.length === 1 && Array.isArray(items[0]) ? items[0] : items), toString: a => '[' + Array.from(a).join(', ') + ']',
        copyOfRange: (a, from, to) => { const out = Array.from(a ?? []).slice(from, to); while (out.length < to - from) out.push(0); return out; }, copyOf: (a, n) => { const out = Array.from(a ?? []).slice(0, n); while (out.length < n) out.push(0); return out; },
        equals: (a, b) => Array.from(a ?? []).join() === Array.from(b ?? []).join(), sort: a => a.sort(), fill: (a, v) => a.fill(v) },
    'java.util.Date': Date, 'java.util.Random': class { nextInt(n) { return Math.floor(Math.random() * (n ?? 2147483647)); } nextDouble() { return Math.random(); } },
    'java.text.SimpleDateFormat': class { constructor(f) { this.f = String(f); } format(d) { return formatDate(d instanceof Date ? d.getTime() : Number(d), this.f, null); } parse(s) { return new Date(String(s).replace(/(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?/, '$1/$2/$3')); } },
    'java.net.URLEncoder': { encode: (s, cs = 'utf-8') => formEncode(String(s), String(cs)) },
    'java.net.URLDecoder': { decode: (s, cs = 'utf-8') => { const text = String(s).replace(/\+/g, ' '); try { return isUTF8(String(cs)) ? decodeURIComponent(text) : decodeBytes(Array.from(text.matchAll(/%([0-9a-fA-F]{2})|([\s\S])/g), m => m[1] ? [parseInt(m[1], 16)] : encodeText(m[2])).flat(), String(cs)); } catch { return text; } } },
    'java.net.URL': class { constructor(a, b) { Object.assign(this, jsURL(b === undefined ? String(a) : String(b), b === undefined ? undefined : String(a))); } getHost() { return this.hostname; } getPath() { return this.pathname; } getQuery() { return this.search.replace(/^\?/, ''); } getProtocol() { return this.protocol.replace(/:$/, ''); } toString() { return this.href; } },
    'java.nio.charset.StandardCharsets': { UTF_8: 'UTF-8', ISO_8859_1: 'ISO-8859-1', US_ASCII: 'US-ASCII', UTF_16: 'UTF-16' },
    'java.nio.charset.Charset': { forName: n => String(n), defaultCharset: () => 'UTF-8' },
    'javax.crypto.Cipher': { ENCRYPT_MODE: 1, DECRYPT_MODE: 2, getInstance: t => cipher(String(t)) },
    // Rhino lets scripts call Java constructors without `new`.
    'javax.crypto.spec.SecretKeySpec': function (key, algorithm) { const keyBytes = toBytes(key); return { keyBytes, algorithm, getEncoded: () => keyBytes, getAlgorithm: () => algorithm }; },
    'javax.crypto.spec.IvParameterSpec': function (iv) { const ivBytes = toBytes(iv); return { ivBytes, getIV: () => ivBytes }; },
    'javax.crypto.Mac': { getInstance: a => mac(String(a)) },
    'java.security.MessageDigest': { getInstance: a => messageDigest(String(a)) },
    'android.util.Base64': androidBase64,
    'android.text.TextUtils': { isEmpty: s => s == null || String(s).length === 0, join: (separator, list) => Array.from(list ?? [], String).join(String(separator)) },
    'android.os.Build': { MODEL: 'Pixel 8', MANUFACTURER: 'Google', BRAND: 'google', DEVICE: 'shiba', PRODUCT: 'shiba', BOARD: 'shiba', VERSION: { SDK_INT: 34, RELEASE: '14' } },
    'android.net.Uri': { encode: s => encodeURIComponent(String(s)), decode: s => { try { return decodeURIComponent(String(s)); } catch { return String(s); } }, parse: s => jsURL(String(s)) },
    'org.jsoup.Jsoup': { parse: (html) => parseDocument(String(html ?? '')), connect: jsoupConnect, clean: html => String(html ?? '').replace(/<[^>]+>/g, '') },
    'org.jsoup.Connection.Method': { GET: { name: () => 'GET' }, POST: { name: () => 'POST' }, PUT: { name: () => 'PUT' }, HEAD: { name: () => 'HEAD' }, DELETE: { name: () => 'DELETE' } },
    'org.jsoup.nodes.Document': Object, 'org.jsoup.nodes.Element': Object,
    'com.google.gson.JsonSyntaxException': SyntaxError, 'com.script.ScriptException': Error, 'org.mozilla.javascript.EcmaError': Error,
};
// OkHttp and Hutool, which some sources drive directly through JavaImporter.
const okhttpResponse = response => ({
    body: () => ({ string: () => response.body(), bytes: () => encodeText(response.body()), contentType: () => response.header('content-type') }),
    code: () => response.code(), isSuccessful: () => response.isSuccessful(), message: () => '', header: (name, fallback = null) => response.header(name) ?? fallback,
    headers: () => ({ names: () => Object.keys(response.headers()), get: name => response.header(name), toMultimap: () => Object.fromEntries(Object.entries(response.headers()).map(([k, v]) => [k, [v]])) }),
    request: () => ({ url: () => response.url() }), close() { },
});
class OkRequestBuilder {
    constructor() { this.r = { url: '', method: 'GET', headers: {}, body: null }; }
    url(u) { this.r.url = String(u); return this; } get() { this.r.method = 'GET'; return this; } head() { this.r.method = 'HEAD'; return this; }
    post(body) { this.r.method = 'POST'; this.r.body = body; return this; } put(body) { this.r.method = 'PUT'; this.r.body = body; return this; }
    method(m, body) { this.r.method = String(m).toUpperCase(); this.r.body = body ?? null; return this; }
    header(k, v) { this.r.headers[String(k)] = String(v); return this; } addHeader(k, v) { return this.header(k, v); } removeHeader(k) { delete this.r.headers[String(k)]; return this; }
    headers(h) { for (const [k, v] of Object.entries(h?.map ?? h ?? {})) this.r.headers[k] = String(v); return this; }
    build() { return { ...this.r, newBuilder: () => Object.assign(new OkRequestBuilder(), { r: { ...this.r, headers: { ...this.r.headers } } }) }; }
}
class OkHttpClient {
    newBuilder() { return { build: () => new OkHttpClient(), connectTimeout() { return this; }, readTimeout() { return this; }, writeTimeout() { return this; }, followRedirects() { return this; }, addInterceptor() { return this; }, cookieJar() { return this; } }; }
    newCall(request) {
        return { execute() {
            const headers = { ...request.headers };
            let body = null;
            if (request.body) { body = request.body.text; if (request.body.type && !hasHeader(headers, 'Content-Type')) headers['Content-Type'] = request.body.type; }
            if ((headers['Content-Encoding'] ?? '').toLowerCase() === 'gzip') delete headers['Content-Encoding'];
            const answer = sendHTTP({ url: request.url, method: request.method, headers, body });
            return okhttpResponse(new StrResponse(answer.url || request.url, decodeAnswer(answer, null), answer.code ?? 0, answer.headers ?? {}));
        } };
    }
}
OkHttpClient.Builder = class { build() { return new OkHttpClient(); } connectTimeout() { return this; } readTimeout() { return this; } writeTimeout() { return this; } followRedirects() { return this; } addInterceptor() { return this; } cookieJar() { return this; } };
const okhttp3 = {
    OkHttpClient, Request: { Builder: OkRequestBuilder },
    MediaType: { parse: s => ({ type: String(s), toString: () => String(s) }), get: s => ({ type: String(s), toString: () => String(s) }) },
    RequestBody: { create: (a, b) => { const [content, type] = typeof a === 'string' || Array.isArray(a) ? [a, b] : [b, a]; return { text: Array.isArray(content) ? latin1(content) : String(content ?? ''), type: type?.type ?? null }; } },
    FormBody: { Builder: class { constructor() { this.parts = []; } add(k, v) { this.parts.push(formEncode(k) + '=' + formEncode(v)); return this; } build() { return { text: this.parts.join('&'), type: 'application/x-www-form-urlencoded' }; } } },
    Headers: { of: (...pairs) => { const map = {}; if (pairs.length === 1 && typeof pairs[0] === 'object') return { map: pairs[0] }; for (let i = 0; i + 1 < pairs.length; i += 2) map[pairs[i]] = pairs[i + 1]; return { map }; } },
};
const hutool = {
    'cn.hutool.core.util.StrUtil': { reverse: s => [...String(s ?? '')].reverse().join(''), isBlank: s => s == null || !String(s).trim(), isEmpty: s => s == null || String(s) === '', isNotBlank: s => s != null && !!String(s).trim(),
        isNotEmpty: s => s != null && String(s) !== '', format: (t, ...a) => { let i = 0; return String(t).replace(/\{\}/g, () => String(a[i++])); }, utf8Str: b => decodeBytes(toBytes(b), 'utf-8'), str: (b, cs) => decodeBytes(toBytes(b), cs ?? 'utf-8'),
        sub: (s, a, b) => String(s).substring(a, b), subBefore: (s, sep) => { const i = String(s).indexOf(sep); return i < 0 ? String(s) : String(s).slice(0, i); }, subAfter: (s, sep) => { const i = String(s).indexOf(sep); return i < 0 ? '' : String(s).slice(i + String(sep).length); } },
    'cn.hutool.core.util.HexUtil': { encodeHexStr: b => hexFromBytes(toBytes(b)), decodeHex: s => bytesFromHex(s), decodeHexStr: s => decodeBytes(bytesFromHex(s), 'utf-8') },
    'cn.hutool.core.util.URLUtil': { encode: (s, cs) => queryEncode(String(s), cs ?? 'utf-8'), decode: s => { try { return decodeURIComponent(String(s).replace(/\+/g, ' ')); } catch { return String(s); } }, encodeQuery: s => formEncode(String(s)) },
    'cn.hutool.core.util.ZipUtil': { gzip: (data, charset) => Array.from(gzip(typeof data === 'string' ? new Uint8Array(encodeText(data, charset || 'utf-8')) : new Uint8Array(toBytes(data)))), unGzip: data => Array.from(ungzip(new Uint8Array(toBytes(data)))) },
    'cn.hutool.core.util.RandomUtil': { randomString: n => Array.from({ length: n }, () => 'abcdefghijklmnopqrstuvwxyz0123456789'[Math.floor(Math.random() * 36)]).join(''), randomInt: (a, b) => b == null ? Math.floor(Math.random() * a) : a + Math.floor(Math.random() * (b - a)), randomNumbers: n => Array.from({ length: n }, () => Math.floor(Math.random() * 10)).join('') },
    'cn.hutool.core.codec.Base64': { encode: (s, cs) => base64FromBytes(typeof s === 'string' ? encodeText(s, cs ?? 'utf-8') : toBytes(s)), encodeUrlSafe: s => base64FromBytes(toBytes(s)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
        decode: s => bytesFromBase64(String(s).replace(/-/g, '+').replace(/_/g, '/')), decodeStr: (s, cs) => decodeBytes(bytesFromBase64(String(s).replace(/-/g, '+').replace(/_/g, '/')), cs ?? 'utf-8') },
    'cn.hutool.crypto.digest.DigestUtil': { md5Hex: s => digest(s, 'MD5', 'hex'), md5Hex16: s => digest(s, 'MD5', 'hex').slice(8, 24), sha1Hex: s => digest(s, 'SHA1', 'hex'), sha256Hex: s => digest(s, 'SHA256', 'hex'), sha512Hex: s => digest(s, 'SHA512', 'hex'),
        md5: s => bytesFromHex(digest(s, 'MD5', 'hex')), sha256: s => bytesFromHex(digest(s, 'SHA256', 'hex')) },
    'cn.hutool.crypto.SecureUtil': { md5: s => digest(s, 'MD5', 'hex'), sha1: s => digest(s, 'SHA1', 'hex'), sha256: s => digest(s, 'SHA256', 'hex'), aes: key => new SymmetricCrypto('AES/ECB/PKCS5Padding', key), des: key => new SymmetricCrypto('DES/ECB/PKCS5Padding', key) },
};
Object.assign(javaClasses, hutool, Object.fromEntries(Object.entries(okhttp3).map(([k, v]) => ['okhttp3.' + k, v])));
const Packages = {};
for (const [name, value] of Object.entries(javaClasses)) {
    const parts = name.split('.');
    let node = Packages;
    for (const part of parts.slice(0, -1)) node = node[part] ??= {};
    node[parts[parts.length - 1]] ??= value;
    if (value && (typeof value === 'object' || typeof value === 'function')) try { Object.defineProperty(value, '__javaName', { value: parts[parts.length - 1], configurable: true }); } catch { }
}
function JavaImporter(...packages) {
    const scope = new.target ? this : {};
    const add = item => {
        if (!item) return;
        if (item.__javaName) scope[item.__javaName] = item;
        else for (const [k, v] of Object.entries(item)) if (v && (typeof v === 'function' || v.__javaName)) scope[k] = v;
    };
    Object.defineProperty(scope, 'importPackage', { value: (...items) => items.forEach(add), configurable: true });
    Object.defineProperty(scope, 'importClass', { value: (...items) => items.forEach(add), configurable: true });
    packages.forEach(add);
    return scope;
}
const safeGlobalImport = item => {
    const add = (k, v) => { if (!(k in globalThis)) globalThis[k] = v; };
    if (!item) return;
    if (item.__javaName) add(item.__javaName, item); else for (const [k, v] of Object.entries(item)) if (v && (typeof v === 'function' || v.__javaName)) add(k, v);
};
Object.assign(globalThis, { Packages, JavaImporter, org: Packages.org, javax: Packages.javax, android: Packages.android, com: Packages.com,
    importPackage: (...items) => items.forEach(safeGlobalImport), importClass: (...items) => items.forEach(safeGlobalImport) });
// `java` is AnalyzeRule in rules, as in Legado, but java.lang.String and friends should still be found there.
for (const name of ['lang', 'util', 'net', 'nio', 'text', 'security']) Object.defineProperty(Analyzer.prototype, name, { value: Packages.java[name] ?? {}, configurable: true, writable: true });

// Jsoup's Elements on arrays of nodes.
for (const [name, fn] of Object.entries({
    toArray() { return Array.from(this); }, isEmpty() { return this.length === 0; }, first() { return this[0] ?? null; }, last() { return this[this.length - 1] ?? null; },
    text() { return this.map(n => isNode(n) ? XPath.jsoupText(n) : String(n)).filter(Boolean).join(' '); },
    html() { return this.map(n => isNode(n) ? innerHTML(n) : String(n)).join('\n'); }, outerHtml() { return this.map(n => isNode(n) ? outerHTML(n) : String(n)).join('\n'); },
    eachText() { return this.map(n => isNode(n) ? XPath.jsoupText(n) : String(n)).filter(Boolean); },
    eachAttr(name) { return this.map(n => attrOf(n, String(name), '')).filter(Boolean); },
    hasText() { return this.some(n => isNode(n) && XPath.jsoupText(n)); },
    select(css) { const out = []; for (const n of this) if (isNode(n)) for (const m of cssSelect(n, css)) if (!out.includes(m)) out.push(m); return out; },
    eq(i) { return this[i] != null ? [this[i]] : []; }, add(v) { this.push(v); return true; }, contains(v) { return this.includes(v); },
})) if (!(name in Array.prototype)) Object.defineProperty(Array.prototype, name, { value: fn, writable: true, configurable: true });
{
    // attr() on arrays only when it is a list of nodes: an array of strings keeps no attr.
    if (!('attr' in Array.prototype)) Object.defineProperty(Array.prototype, 'attr', { value(name) { for (const n of this) { const v = attrOf(n, String(name), ''); if (v) return v; } return ''; }, writable: true, configurable: true });
}

// --- Entry points (NovelRuntime.swift) --------------------------------------------------------
const baselineGlobals = new Set([...Object.getOwnPropertyNames(globalThis), '__legado', '__cryptoJS', 'CryptoJS']);
function resetSourceState() {
    infoHtml.clear(); tocHtml.clear(); memoryCache.clear(); seenCookies.clear(); exploreKindsKept = null;
    // What the last source's jsLib and scripts left in the global scope.
    for (const name of Object.getOwnPropertyNames(globalThis)) if (!baselineGlobals.has(name)) { try { delete globalThis[name]; } catch { } }
}
/// What Rhino parses and QuickJS doesn't: destructured arrow parameters without parentheses.
const rhinoSyntax = code => code.includes('=>') ? code.replace(/(^|[(,=:\s])(\[[\w\s,$]*\]|\{[\w\s,$:]*\})\s*=>/g, '$1($2)=>') : code;
/// Rhino runs jsLib as a script whose top-level `let`/`const` are shared; an indirect eval would keep them to itself.
const globalScript = code => rhinoSyntax(String(code)).replace(/^(let|const)(\s+[A-Za-z_$])/gm, 'var$2');
function load(text) {
    const json = typeof text === 'string' ? JSON.parse(text) : text;
    if (!json || typeof json !== 'object' || !json.bookSourceUrl) fail('This is not a Legado book source.');
    if (json.bookSourceType != null && Number(json.bookSourceType) !== 0) fail('This is not a text book source.');
    resetSourceState();
    S = json; source = makeSource(json);
    globalThis.source = source;
    if (S.jsLib && String(S.jsLib).trim()) {
        const lib = String(S.jsLib).trim();
        const map = lib.startsWith('{') ? lenientJSON(lib) : null;
        try {
            if (map && typeof map === 'object') { for (const url of Object.values(map)) (0, eval)(Analyzer.prototype.cacheFile.call(new Analyzer({}), String(url), 86400)); }
            else (0, eval)(globalScript(lib));
        } catch (error) { log('jsLib failed', String(error?.message ?? error)); }
    }
    return { name: S.bookSourceName ?? S.bookSourceUrl };
}
// Legado keeps book.variable in its database; here the source's store keeps it, by book address, so what the
// table of contents' rules put is there for the chapters' even though the app passes the book it had.
const bookVariablesKey = book => 'book:' + String(book.bookUrl ?? '');
function bookFrom(value) {
    const book = new Book(value ?? {});
    const kept = book.bookUrl ? lenientJSON(store.get('bookvars', bookVariablesKey(book))) : null;
    if (kept && typeof kept === 'object') book.variableMap = { ...book.variableMap, ...kept };
    return book;
}
function keepBook(book) {
    if (!book.bookUrl) return;
    const text = JSON.stringify(stringMap(book.variableMap));
    if (text !== '{}' && text !== store.get('bookvars', bookVariablesKey(book))) store.set('bookvars', bookVariablesKey(book), text);
}
const chapterFrom = (value, book) => new Chapter(value ?? {}, book.bookUrl, book.tocUrl || book.bookUrl);
function run(fn, budget) {
    requestCount = 0;
    deadline = Date.now() + (Number(budget) > 0 ? Number(budget) : 60000);
    try { return { value: fn() }; }
    catch (error) {
        const message = error instanceof LegadoError ? error.message : `${error?.name ?? 'Error'}: ${error?.message ?? error}`;
        log('failed:', message, error?.stack ? String(error.stack).slice(0, 600) : '');
        return { error: message };
    }
    finally { deadline = Infinity; }
}
globalThis.__legado = {
    load: text => run(() => load(text), 15000),
    search: (key, page = 1, budget) => run(() => {
        if (!S.searchUrl) fail('This source cannot search.');
        const ruleData = new RuleData();
        const request = buildRequest(S.searchUrl, { key: String(key), page: Number(page) || 1, baseUrl: S.bookSourceUrl, ruleData });
        return analyzeBookList(performChecked(request, { ruleData }), ruleData, request, true).map(b => b.toNovel());
    }, budget),
    exploreKinds: budget => run(() => exploreKinds(), budget),
    explore: (url, page = 1, budget) => run(() => {
        const ruleData = new RuleData();
        const request = buildRequest(String(url), { page: Number(page) || 1, baseUrl: S.bookSourceUrl, ruleData });
        return analyzeBookList(performChecked(request, { ruleData }), ruleData, request, false).map(b => b.toNovel());
    }, budget),
    info: (value, budget) => run(() => { const book = bookInfo(bookFrom(value)); keepBook(book); return book.toNovel(); }, budget),
    toc: (value, budget) => run(() => {
        let book = bookFrom(value);
        if (!book.tocUrl) book = bookInfo(book);
        const chapters = chapterList(book).map(c => c.toNovel());
        keepBook(book);
        return { book: book.toNovel(), chapters };
    }, budget),
    content: (value, chapterValue, nextValue, budget) => run(() => {
        const book = bookFrom(value);
        if (!book.tocUrl) book.tocUrl = book.bookUrl;
        const chapter = chapterFrom(chapterValue, book);
        const next = nextValue && nextValue.url ? nextValue.url : null;
        const text = chapterContent(book, chapter, next);
        keepBook(book);
        const paragraphs = String(text).split(/\r?\n/).map(line => line.replace(/<img[^>]*>/gi, '').replace(/^[\s　 ]+|[\s　 ]+$/g, '')).filter(Boolean);
        return { title: String(chapter.title ?? ''), paragraphs, variables: stringMap(chapter.variableMap) };
    }, budget),
    // Debugging: a rule run on a text.
    rule: (rule, content, base) => run(() => new Analyzer({}).setContent(String(content), base).getStringList(String(rule))),
};
