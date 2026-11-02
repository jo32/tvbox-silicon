// The host API of Listenify / XPTV music extensions, over the TVBox prelude (which this runs after and
// which supplies `req`, `local`, `md5X`, timers and the console). See MusicExtensions.swift.
// An extension is a plain script: its functions (getConfig, getSongs, getPlaylists, getAlbums, getArtists,
// search, getSongInfo) take and return JSON text.
const host = globalThis.__host;

const argsify = value => {
    if (value == null || value === '') return {};
    if (typeof value !== 'string') return value;
    try { return JSON.parse(value); } catch { return {}; }
};
const jsonify = value => JSON.stringify(value ?? {});

// Each request waits at most this long; the call around it has its own deadline.
const requestTimeout = 10000;
function send(method, url, body, options = {}) {
    const headers = { ...(options.headers || {}) };
    let text;
    if (body != null) {
        if (typeof body === 'string') text = body;
        else {
            text = JSON.stringify(body);
            if (!Object.keys(headers).some(name => name.toLowerCase() === 'content-type')) headers['Content-Type'] = 'application/json';
        }
    }
    const payload = { url: String(url), method, headers, body: text == null ? null : String(text),
        timeout: Math.min(Number(options.timeout) || requestTimeout, requestTimeout), encoding: 'utf-8' };
    // Started without blocking the script, so requests an extension makes side by side (Promise.all) overlap.
    return new Promise(resolve => {
        const done = answer => resolve({ data: answer.content ?? '', status: answer.code ?? 0, statusCode: answer.code ?? 0, headers: answer.headers || {} });
        let id;
        try { id = host('httpStart', JSON.stringify(payload)); } catch (error) { done({ failed: String(error?.message || error) }); return; }
        const poll = () => {
            const text = host('httpPoll', id);
            if (text == null) { setTimeout(poll, 10); return; }
            done(JSON.parse(text));
        };
        setTimeout(poll, 0);
    });
}
const $fetch = {
    get: async (url, options) => send('GET', url, null, options),
    post: async (url, body, options) => send('POST', url, body, options),
    put: async (url, body, options) => send('PUT', url, body, options),
    delete: async (url, options) => send('DELETE', url, null, options),
};

const $cache = {
    get(key) { const text = globalThis.local.get('cache', String(key)); if (!text) return undefined; try { return JSON.parse(text); } catch { return text; } },
    set(key, value) { globalThis.local.set('cache', String(key), JSON.stringify(value ?? null)); },
    del(key) { globalThis.local.delete('cache', String(key)); },
};

const $print = (...values) => globalThis.console.log(...values);
const $utils = { md5: text => globalThis.md5X(String(text)), toastInfo: $print, toastError: $print, openSafari() {} };

// `$lx.request` reaches an LX Music source in Swift, which is asynchronous there: the first call notes what
// was asked and fails; Swift answers it and calls the function again, and the answer is then at hand.
const lxAnswers = new Map();
let lxPending;
const $lx = {
    request(event, data, options) {
        const key = JSON.stringify([String(event), data ?? null, options ?? null]);
        const answer = lxAnswers.get(key);
        if (answer) return answer.error ? Promise.reject(new Error(answer.error)) : Promise.resolve(answer.value);
        lxPending = { key, event: String(event), data: data ?? null, options: options ?? null };
        return Promise.reject(new Error('This extension needs an LX Music source'));
    },
};

Object.assign(globalThis, { argsify, jsonify, $fetch, $cache, $print, $utils, $lx, $config_str: '{}' });

const functions = ['getConfig', 'getSongs', 'getPlaylists', 'getAlbums', 'getArtists', 'search', 'getSongInfo'];
globalThis.__music = {
    // Runs the extension as a classic script, so its function declarations become globals.
    load(config) {
        globalThis.$config_str = typeof config === 'string' && config ? config : '{}';
        (0, eval)(host('module', 'music://extension'));
        return { functions: functions.filter(name => typeof globalThis[name] === 'function') };
    },
    async call(name, argument) {
        lxPending = undefined;
        try {
            if (!functions.includes(name) || typeof globalThis[name] !== 'function') throw new Error(`The extension has no ${name}`);
            const result = await globalThis[name](argument);
            return { result: typeof result === 'string' ? result : JSON.stringify(result ?? {}), lx: lxPending };
        } catch (error) {
            return { error: String(error?.message || error), lx: lxPending };
        }
    },
    answer(key, value, error) {
        lxAnswers.set(key, error ? { error: String(error) } : { value });
        // Answers are per song: keep the map small.
        while (lxAnswers.size > 50) lxAnswers.delete(lxAnswers.keys().next().value);
    },
};
