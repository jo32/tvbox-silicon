// The TVBox script environment on QuickJS. It mirrors Runtime/ScriptHost/host.mjs (the Node host)
// and Android TVBox's QuickJS globals; native work goes through __host(operation, argument).
import * as cheerio from 'assets://js/lib/cheerio.min.js';
import 'assets://js/lib/pako.min.js';

const host = globalThis.__host;
globalThis.global = globalThis; globalThis.window = globalThis; globalThis.self = globalThis;
globalThis.__JS_SPIDER__ = undefined;

// --- Bytes and text -------------------------------------------------------------------------
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const lookup = new Uint8Array(256).fill(255);
for (let i = 0; i < 64; i++) lookup[alphabet.charCodeAt(i)] = i;
lookup['-'.charCodeAt(0)] = 62; lookup['_'.charCodeAt(0)] = 63;
function bytesToBase64(bytes) {
    let out = '';
    for (let i = 0; i < bytes.length; i += 3) {
        const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
        out += alphabet[a >> 2] + alphabet[((a & 3) << 4) | ((b ?? 0) >> 4)]
            + (b === undefined ? '=' : alphabet[((b & 15) << 2) | ((c ?? 0) >> 6)])
            + (c === undefined ? '=' : alphabet[c & 63]);
    }
    return out;
}
function base64ToBytes(text) {
    const clean = String(text).replace(/[^A-Za-z0-9+/\-_]/g, '');
    const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
    let bits = 0, value = 0, index = 0;
    for (let i = 0; i < clean.length; i++) {
        value = (value << 6) | lookup[clean.charCodeAt(i)]; bits += 6;
        if (bits >= 8) { bits -= 8; out[index++] = (value >> bits) & 255; }
    }
    return out.subarray(0, index);
}
const latin1Encode = text => Uint8Array.from(String(text), ch => ch.charCodeAt(0) & 255);
const latin1Decode = bytes => { let s = ''; for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192)); return s; };
const utf8Encode = text => base64ToBytes(host('encode', String(text)));
const decodeBytes = (bytes, encoding = 'utf-8') => host('decode', JSON.stringify({ base64: bytesToBase64(bytes), encoding })) ?? '';

class TextEncoder { get encoding() { return 'utf-8'; } encode(text = '') { return utf8Encode(text); } }
class TextDecoder {
    constructor(encoding = 'utf-8') { this.encoding = String(encoding).toLowerCase(); }
    decode(input) {
        if (input == null) return '';
        const bytes = input instanceof Uint8Array ? input : new Uint8Array(input.buffer ?? input);
        return decodeBytes(bytes, this.encoding);
    }
}

class Buffer extends Uint8Array {
    static from(value, encoding = 'utf8') {
        if (typeof value === 'string') {
            const kind = String(encoding).toLowerCase();
            const bytes = kind === 'base64' || kind === 'base64url' ? base64ToBytes(value)
                : kind === 'hex' ? Uint8Array.from(value.match(/../g) || [], pair => parseInt(pair, 16))
                : kind === 'latin1' || kind === 'binary' || kind === 'ascii' ? latin1Encode(value) : utf8Encode(value);
            return Buffer.of(bytes);
        }
        if (value instanceof ArrayBuffer) return Buffer.of(new Uint8Array(value));
        return Buffer.of(Uint8Array.from(value ?? []));
    }
    static of(bytes) { const buffer = new Buffer(bytes.length); buffer.set(bytes); return buffer; }
    static alloc(size, fill = 0) { return new Buffer(size).fill(fill); }
    static isBuffer(value) { return value instanceof Buffer; }
    static byteLength(text, encoding) { return Buffer.from(text, encoding).length; }
    static concat(list) { const total = list.reduce((n, b) => n + b.length, 0); const out = new Buffer(total); let at = 0; for (const b of list) { out.set(b, at); at += b.length; } return out; }
    toString(encoding = 'utf8', start = 0, end = this.length) {
        const bytes = this.subarray(start, end);
        const kind = String(encoding).toLowerCase();
        if (kind === 'base64') return bytesToBase64(bytes);
        if (kind === 'base64url') return bytesToBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        if (kind === 'hex') return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
        if (kind === 'latin1' || kind === 'binary' || kind === 'ascii') return latin1Decode(bytes);
        return decodeBytes(bytes, kind === 'utf8' ? 'utf-8' : kind);
    }
    toJSON() { return { type: 'Buffer', data: Array.from(this) }; }
}

// --- URL ------------------------------------------------------------------------------------
const formEncode = text => encodeURIComponent(text).replace(/%20/g, '+');
const formDecode = text => { try { return decodeURIComponent(String(text).replace(/\+/g, ' ')); } catch { return text; } };
class URLSearchParams {
    constructor(init = '') {
        this._list = [];
        if (typeof init === 'string') {
            for (const part of init.replace(/^\?/, '').split('&')) {
                if (!part) continue;
                const at = part.indexOf('=');
                this._list.push(at < 0 ? [formDecode(part), ''] : [formDecode(part.slice(0, at)), formDecode(part.slice(at + 1))]);
            }
        } else if (init instanceof URLSearchParams) this._list = init._list.map(pair => [...pair]);
        else if (Array.isArray(init)) this._list = init.map(([k, v]) => [String(k), String(v)]);
        else if (init) for (const key of Object.keys(init)) this._list.push([key, String(init[key])]);
    }
    append(key, value) { this._list.push([String(key), String(value)]); }
    delete(key) { this._list = this._list.filter(([k]) => k !== key); }
    get(key) { const found = this._list.find(([k]) => k === key); return found ? found[1] : null; }
    getAll(key) { return this._list.filter(([k]) => k === key).map(([, v]) => v); }
    has(key) { return this._list.some(([k]) => k === key); }
    set(key, value) { const at = this._list.findIndex(([k]) => k === key); this.delete(key); this._list.splice(at < 0 ? this._list.length : at, 0, [String(key), String(value)]); }
    forEach(callback, self) { for (const [k, v] of this._list) callback.call(self, v, k, this); }
    keys() { return this._list.map(([k]) => k)[Symbol.iterator](); }
    values() { return this._list.map(([, v]) => v)[Symbol.iterator](); }
    entries() { return this._list.map(pair => [...pair])[Symbol.iterator](); }
    [Symbol.iterator]() { return this.entries(); }
    toString() { return this._list.map(([k, v]) => formEncode(k) + '=' + formEncode(v)).join('&'); }
}
class URL {
    constructor(href, base) {
        const parts = JSON.parse(host('url', JSON.stringify({ href: String(href), base: base == null ? null : String(base) })));
        Object.assign(this, parts);
        this.searchParams = new URLSearchParams(this.search);
    }
    toString() { return this.href; }
    toJSON() { return this.href; }
}

// --- Network and storage --------------------------------------------------------------------
let lastFailure;
function remoteError(remote, status, message) { return Object.assign(new Error(message), { remote, status }); }
function request(address, options = {}) {
    const headers = { ...(options.headers || options.header || {}) };
    let body = options.body;
    if (options.data != null) {
        if (options.postType === 'json') { body = JSON.stringify(options.data); headers['Content-Type'] ||= 'application/json'; }
        else { body = new URLSearchParams(options.data).toString(); headers['Content-Type'] ||= 'application/x-www-form-urlencoded'; }
    }
    const payload = { url: String(address), method: String(options.method || 'GET').toUpperCase(), headers,
        body: body == null ? null : String(body), bodyBase64: options.bodyBase64 == null ? null : String(options.bodyBase64),
        timeout: Number(options.timeout || 20000),
        redirect: !(options.redirect === 0 || options.redirect === false), encoding: options.encoding || 'utf-8',
        binary: options.buffer === 1 || options.buffer === 2 || options.buffer === 3 };
    const answer = JSON.parse(host('http', JSON.stringify(payload)));
    let content = answer.content ?? '';
    if (answer.base64 != null) {
        // Decoding large bodies in JavaScript is slow on QuickJS: skip it when base64 is wanted.
        if (options.buffer === 2) content = answer.base64;
        else { const bytes = base64ToBytes(answer.base64); content = options.buffer === 1 ? Array.from(bytes) : bytes; }
    }
    if (answer.failed) lastFailure = remoteError(answer.host, 0, answer.failed);
    else if (answer.code >= 400) lastFailure = remoteError(answer.host, answer.code, `The source ${answer.host} returned HTTP ${answer.code}`);
    else if (lastFailure?.remote === answer.host) lastFailure = undefined;
    const response = { code: answer.code, headers: answer.headers || {}, content, url: answer.url };
    if (typeof options.complete === 'function') options.complete(response);
    return response;
}
const local = {
    get(group, key) { return host('local', JSON.stringify(['get', String(group), String(key)])) || ''; },
    set(group, key, value) { host('local', JSON.stringify(['set', String(group), String(key), String(value)])); },
    delete(group, key) { host('local', JSON.stringify(['delete', String(group), String(key)])); }
};

// --- Timers (run by the native loop through __tvbox.tick) -----------------------------------
const timers = new Map();
let nextTimer = 1;
function addTimer(callback, delay, args, repeat) {
    const id = nextTimer++;
    timers.set(id, { callback, args, delay: Math.max(0, Number(delay) || 0), due: Date.now() + Math.max(0, Number(delay) || 0), repeat });
    return id;
}

const log = (...values) => { host('log', values.map(v => typeof v === 'string' ? v : (() => { try { return JSON.stringify(v); } catch { return String(v); } })()).join(' ')); };
Object.assign(globalThis, {
    console: { log, info: log, warn: log, error: log, debug: log }, print: log, log,
    req: request, _http: request, fetch: request,
    http: (url, options = {}) => options.async === false ? request(url, options) : Promise.resolve(request(url, options)),
    local, URL, URLSearchParams, TextEncoder, TextDecoder, Buffer,
    setTimeout: (callback, delay, ...args) => addTimer(callback, delay, args, false),
    setInterval: (callback, delay, ...args) => addTimer(callback, delay, args, true),
    clearTimeout: id => { timers.delete(id); }, clearInterval: id => { timers.delete(id); },
    joinUrl: (parent, child) => new URL(child, parent).href,
    base64Encode: text => bytesToBase64(utf8Encode(text)),
    base64Decode: text => decodeBytes(base64ToBytes(text)),
    btoa: text => bytesToBase64(latin1Encode(text)),
    atob: text => latin1Decode(base64ToBytes(text)),
    md5X: text => host('md5', String(text)),
    // Native AES/hash/HMAC (ScriptCrypto.swift); binary fields are base64. Mirrored in host.mjs.
    nativeCrypto: request => JSON.parse(host('crypto', JSON.stringify(request))),
    gzip: text => bytesToBase64(globalThis.pako.gzip(utf8Encode(text))),
    ungzip: text => decodeBytes(globalThis.pako.ungzip(base64ToBytes(text))),
    getProxy: () => 'http://127.0.0.1:-1/proxy?do=js', getPort: () => -1,
    s2t: text => text, t2s: text => text
});

// --- HTML selection, as TVBox's pdfh/pdfa/pd ------------------------------------------------
function selectNodes(html, expression, single) {
    const $ = cheerio.load(String(html));
    let node = $.root();
    for (const selector of expression.split('&&').filter(Boolean)) {
        node = node.find(selector.trim());
        if (single) node = node.first();
    }
    return { $, node };
}
globalThis.pdfh = function (html, expression) {
    const parts = expression.split('&&');
    const attribute = parts.pop();
    const { node } = selectNodes(html, parts.join('&&'), true);
    if (attribute === 'Text') return node.text().trim();
    if (attribute === 'Html') return node.html() || '';
    return node.attr(attribute) || '';
};
globalThis.pdfa = function (html, expression) {
    const { $, node } = selectNodes(html, expression, false);
    return node.toArray().map(element => $.html(element));
};
globalThis.pd = function (html, expression, base) {
    const value = globalThis.pdfh(html, expression);
    try { return new URL(value, base).href; } catch { return value; }
};

// --- Spider lifecycle, as host.mjs initialize() and call() ----------------------------------
let spider;
function envelope(error) {
    log(String(error?.stack || error?.message || error));
    if (error?.remote) return { error: error.message, errorCode: error.status ? 'source_http' : 'source_network', host: error.remote, status: error.status };
    return { error: String(error), errorCode: 'script_error' };
}
globalThis.__tvbox = {
    tick() {
        const now = Date.now();
        let next = -1;
        for (const [id, timer] of [...timers]) {
            if (timer.due <= now) {
                if (timer.repeat) timer.due = now + Math.max(1, timer.delay); else timers.delete(id);
                try { timer.callback(...timer.args); } catch (error) { log('timer', String(error)); }
            }
        }
        for (const timer of timers.values()) next = next < 0 ? timer.due - now : Math.min(next, timer.due - now);
        return next < 0 ? -1 : Math.max(0, next);
    },
    async init(input) {
        try {
            const namespace = await import(input.api);
            spider = globalThis.__JS_SPIDER__;
            let extension = input.ext || '';
            if (namespace.__jsEvalReturn) {
                spider ||= namespace.__jsEvalReturn();
                extension = { stype: 3, skey: input.key, ext: extension };
            } else if (!spider) spider = typeof namespace.default === 'function' ? namespace.default() : namespace.default;
            if (!spider) throw new Error('The script exports no spider');
            if (typeof spider.init === 'function') await spider.init(extension);
            return { ready: true };
        } catch (error) { return envelope(error); }
    },
    async call(params) {
        try {
            lastFailure = undefined;
            let method, args;
            if ('play' in params) { method = 'play'; args = [params.flag || '', params.play, []]; }
            else if ('ids' in params) { method = 'detail'; args = [params.ids]; }
            else if ('wd' in params) { method = 'search'; args = [params.wd, false, params.pg || '1']; }
            else if ('t' in params) { method = 'category'; args = [params.t, params.pg || '1', true, {}]; }
            else { method = 'home'; args = [true]; }
            if (typeof spider?.[method] !== 'function') throw new Error(`The script does not implement ${method}`);
            let result = await spider[method](...args);
            if (result == null || result === '') {
                if (lastFailure) throw lastFailure;
                result = {};
            }
            if (method === 'home' && typeof spider.homeVod === 'function') {
                const home = typeof result === 'string' ? JSON.parse(result) : result;
                const raw = await spider.homeVod();
                const videos = typeof raw === 'string' && raw ? JSON.parse(raw) : raw;
                if (videos?.list?.length) home.list = videos.list;
                result = home;
            }
            return { result: typeof result === 'string' ? result : JSON.stringify(result) };
        } catch (error) { return envelope(error); }
    }
};
