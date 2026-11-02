// LX Music custom sources (洛雪音乐自定义源) on the TVBox prelude: the `lx` object of LX Music
// desktop's user API (src/main/modules/userApi/renderer/preload.js, API version 2.0.0), for the
// musicUrl action only. MusicLXSources.swift drives it through __lx.load and __lx.musicUrl.
const host = globalThis.__host;
const EVENT_NAMES = Object.freeze({ request: 'request', inited: 'inited', updateAlert: 'updateAlert' });
const sourceKeys = ['kw', 'kg', 'tx', 'wy', 'mg'];
const qualities = ['128k', '320k', 'flac', 'flac24bit'];
// MusicLXSources gives a whole lookup 8 seconds.
const requestLimit = 8000;

let requestHandler = null;
let inited = null;
let initedResolve;
const initedPromise = new Promise(resolve => { initedResolve = resolve; });

const toBuffer = value => value instanceof Uint8Array ? Buffer.from(value) : Buffer.from(String(value ?? ''), 'utf8');
const crypto = request => JSON.parse(host('crypto', JSON.stringify(request)));
const formBody = data => typeof data === 'string' ? data : new URLSearchParams(data).toString();

function send(eventName, data) {
    return new Promise((resolve, reject) => {
        if (eventName === EVENT_NAMES.inited) {
            if (inited) return reject(new Error('Script is inited'));
            inited = data || {};
            initedResolve();
            return resolve();
        }
        // Update notices from the script's author are not shown.
        if (eventName === EVENT_NAMES.updateAlert) return resolve();
        reject(new Error('The event is not supported: ' + eventName));
    });
}

function on(eventName, handler) {
    if (eventName !== EVENT_NAMES.request) return Promise.reject(new Error('The event is not supported: ' + eventName));
    requestHandler = handler;
    return Promise.resolve();
}

/// needle's behaviour as LX uses it: the answer's body is parsed as JSON when it is JSON.
function request(url, options, callback) {
    if (typeof options === 'function') { callback = options; options = {}; }
    const { method = 'get', timeout, headers = {}, body, form, formData } = options || {};
    let cancelled = false;
    Promise.resolve().then(() => {
        if (cancelled) return;
        const fields = {};
        for (const [key, value] of Object.entries(headers || {})) if (value != null) fields[key] = String(value);
        const has = name => Object.keys(fields).some(key => key.toLowerCase() === name);
        let payload = null;
        if (body != null) {
            if (typeof body === 'string' || body instanceof Uint8Array) payload = body;
            else if (has('content-type') && /json/i.test(Object.entries(fields).find(([key]) => key.toLowerCase() === 'content-type')[1])) payload = JSON.stringify(body);
            else { payload = formBody(body); if (!has('content-type')) fields['Content-Type'] = 'application/x-www-form-urlencoded'; }
        } else if (form != null || formData != null) {
            payload = formBody(form ?? formData);
            if (!has('content-type')) fields['Content-Type'] = 'application/x-www-form-urlencoded';
        }
        const wait = typeof timeout === 'number' && timeout > 0 ? Math.min(timeout, requestLimit) : requestLimit;
        const binary = payload instanceof Uint8Array;
        // Started natively and polled from a timer, so a script's parallel requests run in parallel and the
        // lookup's deadline still applies while it waits.
        let id;
        try {
            id = host('httpStart', JSON.stringify({
                url: String(url), method: String(method).toUpperCase(), headers: fields, timeout: wait,
                body: payload == null || binary ? null : String(payload), bodyBase64: binary ? Buffer.from(payload).toString('base64') : null,
                binary: true
            }));
        } catch (error) { deliver({ failed: String(error?.message || error) }); return; }
        const poll = () => {
            if (cancelled) { host('httpCancel', id); return; }
            const text = host('httpPoll', id);
            if (text == null) { setTimeout(poll, 10); return; }
            deliver(JSON.parse(text));
        };
        setTimeout(poll, 0);
    }).catch(() => {});
    const deliver = answer => {
        if (answer.failed) { try { callback?.call(this, new Error(answer.failed), null, null); } catch {} return; }
        const raw = Buffer.from(answer.base64 || '', 'base64');
        let parsed = raw.toString('utf8');
        try { parsed = JSON.parse(parsed); } catch {}
        try { callback?.call(this, null, { statusCode: answer.code, statusMessage: '', headers: answer.headers || {}, bytes: raw.length, raw, body: parsed }, parsed); } catch {}
    };
    return () => { cancelled = true; };
}

const utils = {
    crypto: {
        aesEncrypt(buffer, mode, key, iv) {
            const ecb = /ecb/i.test(String(mode));
            const answer = crypto({ op: 'aes', encrypt: true, mode: ecb ? 'ECB' : 'CBC', padding: true,
                data: toBuffer(buffer).toString('base64'), key: toBuffer(key).toString('base64'), iv: ecb ? '' : toBuffer(iv).toString('base64') });
            return Buffer.from(answer.data, 'base64');
        },
        rsaEncrypt(buffer, key) {
            const answer = crypto({ op: 'rsaRaw', key: String(key), data: toBuffer(buffer).toString('base64') });
            return Buffer.from(answer.data, 'base64');
        },
        randomBytes(size) { return Buffer.from(crypto({ op: 'random', count: Number(size) }).data, 'base64'); },
        md5(value) {
            if (typeof value === 'string') return host('md5', value);
            return crypto({ op: 'hash', alg: 'md5', data: toBuffer(value).toString('base64') }).hex;
        }
    },
    buffer: {
        from(...args) { return Buffer.from(...args); },
        bufToString(buf, format) { return (typeof buf === 'string' ? Buffer.from(buf, 'binary') : toBuffer(buf)).toString(format); }
    },
    zlib: {
        inflate(buf) {
            return new Promise(resolve => resolve(Buffer.from(crypto({ op: 'inflate', data: toBuffer(buf).toString('base64'), output: 'base64' }).data, 'base64')));
        },
        deflate(data) { return new Promise(resolve => resolve(Buffer.from(globalThis.pako.deflate(toBuffer(data))))); }
    }
};

const info = JSON.parse(host('module', 'lx://info'));
const silent = () => {};
// Scripts print their requests, keys included; none of it reaches the app's logs. Every console method
// (group, groupEnd, table, time...) exists, as in a browser.
globalThis.console = new Proxy({}, { get: () => silent });
globalThis.lx = Object.freeze({
    EVENT_NAMES, request, send, on, utils, version: '2.0.0', env: 'desktop',
    currentScriptInfo: Object.freeze({ ...info, rawScript: '' })
});

globalThis.__lx = {
    /// Runs the script as LX does (a classic script, not a module) and waits for its inited event.
    /// Answers {sources: {tx: ['128k', ...], ...}} with the sources that resolve music URLs.
    async load() {
        try {
            (0, eval)(host('module', 'lx://script'));
            await initedPromise;
            const sources = {};
            for (const key of sourceKeys) {
                const entry = inited.sources?.[key];
                if (!entry || entry.type !== 'music' || !Array.isArray(entry.actions) || !entry.actions.includes('musicUrl')) continue;
                sources[key] = qualities.filter(quality => Array.isArray(entry.qualitys) && entry.qualitys.includes(quality));
            }
            if (!requestHandler) return { error: 'The source registered no request handler' };
            return { sources };
        } catch (error) { return { error: String(error?.message || error) }; }
    },
    /// One musicUrl request: {source, quality, musicInfo}. Answers {url} or {error}.
    async musicUrl(input) {
        try {
            if (!requestHandler) throw new Error('The source registered no request handler');
            const url = await requestHandler({ source: input.source, action: 'musicUrl', info: { type: input.quality, musicInfo: input.musicInfo } });
            if (typeof url !== 'string' || url.length > 2048 || !/^https?:/.test(url)) throw new Error('The source returned no address');
            return { url };
        } catch (error) { return { error: String(error?.message || error).slice(0, 300) }; }
    }
};
