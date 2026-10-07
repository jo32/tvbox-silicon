// Shared helpers for the lite site scripts. Every site is an ES module whose default export is a
// CatVod spider object (init/home/homeVod/category/detail/search/play) returning CatVod JSON.
// They run on the app's QuickJS runtime (macOS, iOS, tvOS) and the Mac Node script host.
import 'assets://js/lib/crypto-js.js';
import 'assets://js/lib/jsencrypt.js';
import * as cheerio from 'assets://js/lib/cheerio.min.js';

// --- HTML, with jsoup-like helpers ----------------------------------------------------------
/** Parse HTML; returns a cheerio root `$`. */
export const parseHTML = html => cheerio.load(String(html || ''));
/** jsoup Element.text(): whitespace-normalized, trimmed. */
export const textOf = node => (node && node.length ? node.text() : '').replace(/\s+/g, ' ').trim();
/** First match's normalized text, or ''. */
export const firstText = ($, scope, selector) => textOf((scope ? $(scope).find(selector) : $(selector)).first());
/** First non-empty attribute among `names` on the first match, or ''. */
export function firstAttr($, scope, selector, ...names) {
    const node = (scope ? $(scope).find(selector) : $(selector)).first();
    if (!node.length) return '';
    for (const name of names) { const value = (node.attr(name) || '').trim(); if (value) return value; }
    return '';
}
/** Regex group 1 (dot matches newlines like Pattern.DOTALL), trimmed, or ''. */
export function match(pattern, input, flags = 's') {
    const found = new RegExp(pattern, flags).exec(String(input || ''));
    return found ? String(found[1] || '').trim() : '';
}
/** Last run of digits in a string (several spiders take ids from hrefs this way). */
export function lastNumber(value) {
    const all = String(value || '').match(/\d+/g);
    return all ? all[all.length - 1] : '';
}
/** Resolve `path` against `base` like the spiders' `a()` helpers. */
export function absolute(base, path) {
    if (!path) return '';
    if (/^https?:/.test(path)) return path;
    if (path.startsWith('//')) return 'https:' + path;
    return path.startsWith('/') ? base + path : base + '/' + path;
}

export const CryptoJS = globalThis.CryptoJS;
const utf8 = text => CryptoJS.enc.Utf8.parse(String(text));

// Hosts provide nativeCrypto (ScriptCrypto.swift / host.mjs); CryptoJS is the fallback.
const native = typeof globalThis.nativeCrypto === 'function' ? globalThis.nativeCrypto : null;
const hash = (alg, text) => native ? native({ op: 'hash', alg, dataText: String(text) }).hex : CryptoJS[alg.toUpperCase()](String(text)).toString();
export const md5 = text => hash('md5', text);
export const sha1 = text => hash('sha1', text);
export const sha256 = text => hash('sha256', text);
export const hmacSha256 = (text, key) => native ? native({ op: 'hmac', alg: 'sha256', keyText: String(key), dataText: String(text) }).hex : CryptoJS.HmacSHA256(String(text), String(key)).toString();

/** AES with UTF-8 key/iv strings, PKCS7 padding. Returns hex (output: 'hex') or base64. */
export function aesEncrypt(text, key, iv, { mode = 'CBC', output = 'base64' } = {}) {
    if (native) {
        const answer = native({ op: 'aes', encrypt: true, mode, keyText: String(key), ivText: mode === 'ECB' ? '' : String(iv), dataText: String(text), output: output === 'hex' ? 'hex' : 'base64' });
        return output === 'hex' ? answer.hex : answer.data;
    }
    const options = { mode: CryptoJS.mode[mode], padding: CryptoJS.pad.Pkcs7 };
    if (mode !== 'ECB') options.iv = utf8(iv);
    const cipher = CryptoJS.AES.encrypt(utf8(text), utf8(key), options).ciphertext;
    return output === 'hex' ? cipher.toString(CryptoJS.enc.Hex) : cipher.toString(CryptoJS.enc.Base64);
}

/** Inverse of aesEncrypt: `data` is hex (input: 'hex') or base64; returns UTF-8 text. */
export function aesDecrypt(data, key, iv, { mode = 'CBC', input = 'base64' } = {}) {
    if (native) {
        const request = { op: 'aes', encrypt: false, mode, keyText: String(key), ivText: mode === 'ECB' ? '' : String(iv), output: 'text' };
        request[input === 'hex' ? 'dataHex' : 'data'] = String(data).trim();
        return native(request).text;
    }
    const options = { mode: CryptoJS.mode[mode], padding: CryptoJS.pad.Pkcs7 };
    if (mode !== 'ECB') options.iv = utf8(iv);
    const cipher = (input === 'hex' ? CryptoJS.enc.Hex : CryptoJS.enc.Base64).parse(String(data).trim());
    return CryptoJS.AES.decrypt({ ciphertext: cipher }, utf8(key), options).toString(CryptoJS.enc.Utf8);
}

/** RSA PKCS#1 v1.5 with a base64 SubjectPublicKeyInfo key; returns base64. */
export function rsaEncrypt(text, publicKey) {
    const rsa = new globalThis.JSEncrypt();
    rsa.setPublicKey(publicKey);
    const result = rsa.encrypt(String(text));
    if (!result) throw new Error('RSA encryption failed');
    return result;
}

/** RSA PKCS#1 v1.5 with a base64 PKCS#1 or PKCS#8 private key; `data` is base64. */
export function rsaDecrypt(data, privateKey) {
    const rsa = new globalThis.JSEncrypt();
    rsa.setPrivateKey(privateKey.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''));
    const result = rsa.decrypt(String(data));
    if (result === false || result == null) throw new Error('RSA decryption failed');
    return result;
}

export function randomHex(bytes) {
    let out = '';
    for (let i = 0; i < bytes; i++) out += Math.floor(Math.random() * 256).toString(16).padStart(2, '0');
    return out;
}

/** Synchronous HTTP through the host. Throws on network failure or HTTP >= 400. */
export function http(url, options = {}) {
    const response = globalThis.req(url, options);
    if (!response || response.code === 0 || response.code == null) throw new Error('Network request to ' + url + ' failed');
    if (response.code >= 400 && !options.allowError) throw new Error('HTTP ' + response.code + ' from ' + url);
    return response;
}

export function httpJSON(url, options = {}) {
    const response = http(url, options);
    try { return JSON.parse(response.content); }
    catch { throw new Error('Non-JSON response from ' + url + ': ' + String(response.content).slice(0, 120)); }
}

export const formBody = data => Object.keys(data).map(k => encodeURIComponent(k) + '=' + encodeURIComponent(data[k] == null ? '' : data[k])).join('&');

/** Per-site persistent storage, shared across app launches. */
export function store(site) {
    return {
        get: key => globalThis.local.get('lite_' + site, key),
        set: (key, value) => globalThis.local.set('lite_' + site, key, value == null ? '' : String(value)),
        json(key) { try { return JSON.parse(this.get(key) || 'null'); } catch { return null; } },
        setJSON(key, value) { this.set(key, JSON.stringify(value)); }
    };
}

/** Sort play-source names by resolution, highest first, as several spiders do. */
export function resolutionRank(name) {
    const upper = String(name || '').toUpperCase();
    if (upper.includes('4K') || upper.includes('2160')) return 2160;
    for (const value of [1080, 720, 480, 360]) if (upper.includes(String(value))) return value;
    return parseInt(upper.replace(/[^0-9]/g, ''), 10) || 0;
}

export const text = value => value == null ? '' : String(value);

/** Proof-of-work nonce via the host (see ScriptCrypto.proofOfWork); '' when unsolved. */
export function proofOfWork(options) {
    if (native) return native({ op: 'pow', ...options }).nonce || '';
    const digest = options.alg === 'md5' ? md5 : sha256;
    const target = String(options.target).toLowerCase();
    const deadline = Date.now() + (options.limitMs ?? 20000);
    for (let nonce = options.start || 0; nonce <= (options.end ?? 2100000); nonce++) {
        const hex = digest(options.prefix + nonce);
        if (options.match === 'equal' ? hex === target : hex.startsWith(target)) return String(nonce);
        if ((nonce & 1023) === 0 && Date.now() > deadline) break;
    }
    return '';
}

/** java.util.Random, bit-exact (some sites recompute seeded "random" signatures server-side). */
export class JavaRandom {
    constructor(seed) { this.seed = (BigInt(seed) ^ 0x5DEECE66Dn) & ((1n << 48n) - 1n); }
    next(bits) {
        this.seed = (this.seed * 0x5DEECE66Dn + 0xBn) & ((1n << 48n) - 1n);
        return BigInt.asIntN(32, this.seed >> BigInt(48 - bits));
    }
    nextInt(bound) {
        const n = BigInt(bound);
        if ((bound & -bound) === bound) return Number((n * this.next(31)) >> 31n);
        let bits, value;
        do { bits = this.next(31); value = bits % n; } while (BigInt.asIntN(32, bits - value + (n - 1n)) < 0n);
        return Number(value);
    }
}

/** A minimal cookie jar: name -> value, fed from Set-Cookie headers (comma-joined or arrays). */
export class CookieJar {
    constructor(initial = '') { this.map = new Map(); this.add(initial); }
    add(header) {
        for (const pair of String(header || '').split(';')) {
            const at = pair.indexOf('=');
            if (at > 0) { const k = pair.slice(0, at).trim(), v = pair.slice(at + 1).trim(); if (v) this.map.set(k, v); else this.map.delete(k); }
        }
    }
    /** Absorb a response's Set-Cookie headers (first name=value of each cookie, honouring Max-Age=0). */
    absorb(headers) {
        let raw = headers && (headers['set-cookie'] ?? headers['Set-Cookie']);
        if (!raw) return;
        const cookies = Array.isArray(raw) ? raw : String(raw).split(/,(?=\s*[^;,=\s]+=)/);
        for (const cookie of cookies) {
            const [first, ...attributes] = cookie.split(';');
            const at = first.indexOf('=');
            if (at <= 0) continue;
            const name = first.slice(0, at).trim(), value = first.slice(at + 1).trim();
            const expired = attributes.some(a => /^\s*max-age\s*=\s*-?0+\s*$/i.test(a) || /^\s*max-age\s*=\s*-/i.test(a));
            if (!value || expired) this.map.delete(name); else this.map.set(name, value);
        }
    }
    remove(name) { this.map.delete(name); }
    toString() { return [...this.map].map(([k, v]) => `${k}=${v}`).join('; '); }
}
