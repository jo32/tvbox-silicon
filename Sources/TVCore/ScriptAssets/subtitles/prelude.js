// Subtitle sources on QuickJS (SubtitleScriptProvider.swift, #576 M2). This runs after the TVBox prelude and takes
// away what a source must not use: the raw host, the synchronous request functions and the plain-text store.
// A source is a classic script that sets
//
//     subtitleSource = {
//         manifest: { schema: 1, id, name, version, minimumHost: 1, domains: ['api.example.com'], languages, credentials },
//         async search(hint, context) { return [{ id, title, language, format, forced, hearingImpaired, season, episode,
//                                                 fileMatch, downloads, url, token }] },
//         async resolve(candidate, context) { return { url, headers, name, format, expires } or { text, name, format } },
//     };
//
// `hint` is { title, year, season, episode, imdbID, tmdbID, fileName, languages }; `context` is { credentials, languages }.
// Requests go through `$http` and reach only the manifest's domains. Failures are `throw new SubtitleError(kind, message)`
// with kind one of the `kinds` below. Docs/subtitles.md has the whole contract.
const host = globalThis.__host;
const timer = globalThis.setTimeout;
for (const name of ['__host', 'req', '_http', 'fetch', 'http', 'local', 'getProxy', 'getPort']) delete globalThis[name];
// Nothing a source prints reaches the log: it could be a key, a signed address or a line of the subtitles.
const quiet = () => {};
globalThis.console = { log: quiet, info: quiet, warn: quiet, error: quiet, debug: quiet };
globalThis.print = quiet; globalThis.log = quiet;

const kinds = ['timeout', 'rateLimited', 'noResults', 'authRequired', 'authExpired', 'incompatible', 'downloadFailed', 'blocked', 'failed'];
class SubtitleError extends Error {
    constructor(kind, message, retryAfter) {
        super(message || kind);
        this.kind = kinds.includes(kind) ? kind : 'failed';
        this.retryAfter = retryAfter;
    }
    // The usual meaning of an HTTP status that isn't a success.
    static from(response, what) {
        const status = response.status;
        const retry = Number(response.headers['retry-after']) || undefined;
        if (status === 401) return new SubtitleError('authExpired', what);
        if (status === 403) return new SubtitleError('authRequired', what);
        if (status === 429) return new SubtitleError('rateLimited', what, retry);
        if (status === 404) return new SubtitleError('noResults', what);
        if (status === 406 || status === 410) return new SubtitleError('downloadFailed', what);
        return new SubtitleError('failed', `${what || 'The source'} answered HTTP ${status}`);
    }
}

const requestTimeout = 8000;
function start(payload) {
    return new Promise((resolve, reject) => {
        let id;
        try { id = host('subtitle.httpStart', JSON.stringify(payload)); }
        catch (error) {
            const message = String(error?.message || error);
            reject(message.startsWith('blocked:') ? new SubtitleError('blocked', message.slice(8)) : new SubtitleError('failed', message));
            return;
        }
        const poll = () => {
            const text = host('subtitle.httpPoll', id);
            if (text == null) { timer(poll, 10); return; }
            resolve(JSON.parse(text));
        };
        timer(poll, 0);
    });
}

function withQuery(address, query) {
    if (!query) return address;
    // In the order given: some APIs (OpenSubtitles) want their parameters sorted and redirect otherwise.
    const pairs = Object.entries(query).filter(([, value]) => value != null && value !== '')
        .map(([key, value]) => encodeURIComponent(key) + '=' + encodeURIComponent(String(value)).replace(/%2C/gi, ','));
    if (!pairs.length) return address;
    return address + (address.includes('?') ? '&' : '?') + pairs.join('&');
}

async function request(method, url, options = {}) {
    const headers = { ...(options.headers || {}) };
    let body = options.body;
    if (body != null && typeof body !== 'string') {
        body = JSON.stringify(body);
        if (!Object.keys(headers).some(name => name.toLowerCase() === 'content-type')) headers['Content-Type'] = 'application/json';
    }
    let address = withQuery(String(url), options.query);
    for (let hop = 0; ; hop++) {
        const answer = await start({ url: address, method, headers, body: body ?? null,
            timeout: Math.min(Number(options.timeout) || requestTimeout, requestTimeout), encoding: options.encoding || 'utf-8' });
        if (answer.failed) throw new SubtitleError('failed', answer.failed);
        const status = answer.code ?? 0;
        const location = answer.headers?.location;
        // Each hop goes through the host again, so a redirect can't leave the manifest's sites either.
        if ([301, 302, 303, 307, 308].includes(status) && location && hop < 3) {
            address = new URL(location, address).href;
            if (status === 303) { method = 'GET'; body = null; }
            continue;
        }
        const text = answer.content ?? '';
        return {
            status, ok: status >= 200 && status < 300, headers: answer.headers || {}, text, url: address,
            json() {
                try { return JSON.parse(text); }
                catch { throw new SubtitleError('failed', 'The source answered something other than JSON'); }
            },
        };
    }
}

const $http = {
    request,
    get: (url, options) => request('GET', url, options),
    post: (url, body, options = {}) => request('POST', url, { ...options, body }),
};

Object.assign(globalThis, { $http, SubtitleError });

globalThis.__subtitles = {
    // Runs the source as a classic script and answers its manifest.
    load() {
        // Declarations in eval'd code stay inside it (`const subtitleSource = ...` too): the source is read from the
        // eval's own completion value instead.
        const script = host('module', 'subtitles://source');
        const source = (0, eval)(script + '\n;typeof subtitleSource === "undefined" ? globalThis.subtitleSource : subtitleSource');
        globalThis.subtitleSource = source;
        if (!source || typeof source.search !== 'function' || typeof source.resolve !== 'function') {
            throw new Error('The script does not set subtitleSource with search and resolve');
        }
        return source.manifest ?? null;
    },
    async call(name, argument, context) {
        try {
            if (name !== 'search' && name !== 'resolve') throw new SubtitleError('incompatible', `no ${name}`);
            const value = await globalThis.subtitleSource[name](argument, context);
            return { value: value ?? null };
        } catch (error) {
            return { error: { kind: kinds.includes(error?.kind) ? error.kind : 'failed', message: String(error?.message || error).slice(0, 300),
                retryAfter: Number(error?.retryAfter) || null } };
        }
    },
};
