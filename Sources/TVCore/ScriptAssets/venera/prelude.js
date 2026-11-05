// Venera comic sources on QuickJS (MangaRuntime.swift). Venera's own API script (init.js, GPL-3.0, from
// github.com/venera-app/venera) builds every API on one function, `sendMessage`; this module answers it
// with the TVBox prelude (timers, Buffer, URL, cheerio) and the native host (`__host`, MangaHost.swift).
// It runs after the TVBox prelude; init.js runs after it as a global script, then the source.
import * as cheerio from 'assets://js/lib/cheerio.min.js';

const host = globalThis.__host;
const timer = globalThis.setTimeout;          // the TVBox prelude's; init.js replaces setTimeout with its own
const log = text => host('log', String(text));
globalThis.appVersion = '1.6.0';

// --- Bytes ----------------------------------------------------------------------------------
function toBytes(value) {
    if (value == null) return new Uint8Array(0);
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    if (Array.isArray(value)) return Uint8Array.from(value);
    if (typeof value === 'string') return new TextEncoder().encode(value);
    return new Uint8Array(0);
}
const toBase64 = value => Buffer.from(toBytes(value)).toString('base64');
function fromBase64(text) {
    const bytes = Buffer.from(String(text || ''), 'base64');
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}
const fromHex = hex => { const out = new Uint8Array(hex.length / 2); for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16); return out.buffer; };
const native = request => JSON.parse(host('crypto', JSON.stringify(request)));
const manga = (operation, request) => {
    const text = host('manga.' + operation, JSON.stringify(request ?? null));
    return text == null ? null : JSON.parse(text);
};

// --- Convert --------------------------------------------------------------------------------
function convert(message) {
    const { type, value, isEncode } = message;
    switch (type) {
        case 'utf8': return isEncode ? toBytes(String(value)).slice().buffer : new TextDecoder().decode(toBytes(value));
        case 'gbk': return isEncode ? fromBase64(manga('encode', { text: String(value), encoding: 'gbk' })) : new TextDecoder('gbk').decode(toBytes(value));
        case 'base64': return isEncode ? toBase64(value) : fromBase64(value);
        case 'md5': case 'sha1': case 'sha256': case 'sha512':
            return fromHex(native({ op: 'hash', alg: type, data: toBase64(value) }).hex);
        case 'hmac': {
            const hex = native({ op: 'hmac', alg: message.hash, key: toBase64(message.key), data: toBase64(value) }).hex;
            return message.isString ? hex : fromHex(hex);
        }
        case 'aes-ecb': case 'aes-cbc':
            // Venera runs the block cipher alone: no padding is added or removed.
            return fromBase64(native({ op: 'aes', encrypt: !!isEncode, mode: type === 'aes-ecb' ? 'ECB' : 'CBC', padding: false,
                key: toBase64(message.key), iv: toBase64(message.iv), data: toBase64(value) }).data);
        case 'aes-cfb': case 'aes-ofb':
            return fromBase64(manga('cipher', { mode: type.slice(4), encrypt: !!isEncode, blockSize: message.blockSize ?? 16,
                key: toBase64(message.key), iv: toBase64(message.iv), data: toBase64(value) }));
        case 'rsa':
            return isEncode ? null : fromBase64(manga('rsaDecrypt', { key: String(message.key), data: toBase64(value) }));
        default: return value;
    }
}

// --- HTML, on cheerio ------------------------------------------------------------------------
const documents = new Map();
const isElement = node => node && (node.type === 'tag' || node.type === 'script' || node.type === 'style');
function html(message) {
    if (message.function === 'parse') {
        documents.set(message.key, { $: cheerio.load(String(message.data ?? '')), elements: [], nodes: [] });
        while (documents.size > 32) documents.delete(documents.keys().next().value);
        return null;
    }
    if (message.function === 'dispose') { documents.delete(message.key); return null; }
    const docKey = ['querySelector', 'querySelectorAll', 'getElementById'].includes(message.function) ? message.key : message.doc;
    const doc = documents.get(docKey);
    if (!doc) throw new Error('The HTML document was disposed');
    const { $ } = doc;
    const keep = element => { if (!element) return null; doc.elements.push(element); return doc.elements.length - 1; };
    const keepAll = list => list.map(element => keep(element));
    const element = doc.elements[message.key];
    const sibling = (node, step) => { let next = node?.[step]; while (next && !isElement(next)) next = next[step]; return next ?? null; };
    switch (message.function) {
        case 'querySelector': return keep($(message.query).get(0));
        case 'querySelectorAll': return keepAll($(message.query).toArray());
        case 'getElementById': return keep($(`[id="${String(message.id).replace(/"/g, '\\"')}"]`).get(0));
        case 'getText': return $(element).text();
        case 'getAttributes': return { ...(element?.attribs ?? {}) };
        case 'dom_querySelector': return keep($(element).find(message.query).get(0));
        case 'dom_querySelectorAll': return keepAll($(element).find(message.query).toArray());
        case 'getChildren': return keepAll((element?.children ?? []).filter(isElement));
        case 'getNodes': return (element?.children ?? []).map(node => { doc.nodes.push(node); return doc.nodes.length - 1; });
        case 'getInnerHTML': return $(element).html() ?? '';
        case 'getParent': return isElement(element?.parent) ? keep(element.parent) : null;
        case 'getClassNames': return String(element?.attribs?.class ?? '').split(/\s+/).filter(Boolean);
        case 'getId': return element?.attribs?.id ?? '';
        case 'getLocalName': return element?.name ?? '';
        case 'getPreviousSibling': return keep(sibling(element, 'prev'));
        case 'getNextSibling': return keep(sibling(element, 'next'));
        case 'node_text': { const node = doc.nodes[message.key]; return node?.type === 'text' ? node.data : $(node).text(); }
        case 'node_type': {
            const node = doc.nodes[message.key];
            return isElement(node) ? 'element' : node?.type === 'text' ? 'text' : node?.type === 'comment' ? 'comment' : node?.type === 'root' ? 'document' : 'unknown';
        }
        case 'node_toElement': case 'node_to_element': { const node = doc.nodes[message.key]; return isElement(node) ? keep(node) : null; }
    }
    return null;
}

// --- HTTP -----------------------------------------------------------------------------------
function requestBody(data, headers) {
    if (data == null) return null;
    if (typeof data === 'string') return toBase64(data);
    if (data instanceof ArrayBuffer || ArrayBuffer.isView(data) || Array.isArray(data)) return toBase64(data);
    const type = Object.keys(headers).find(name => name.toLowerCase() === 'content-type');
    if (type && /x-www-form-urlencoded/i.test(headers[type])) return toBase64(new URLSearchParams(data).toString());
    if (!type) headers['Content-Type'] = 'application/json';
    return toBase64(JSON.stringify(data));
}
function http(message) {
    const headers = {};
    for (const [name, value] of Object.entries(message.headers || {})) if (value != null) headers[name] = String(value);
    const request = { url: String(message.url), method: String(message.http_method || 'GET').toUpperCase(), headers,
        body: requestBody(message.data, headers), bytes: !!message.bytes };
    return new Promise(resolve => {
        let id;
        try { id = host('manga.httpStart', JSON.stringify(request)); }
        catch (error) { resolve({ status: null, headers: {}, body: null, error: String(error?.message || error) }); return; }
        const poll = () => {
            const text = host('manga.httpPoll', id);
            if (text == null) { timer(poll, 8); return; }
            const answer = JSON.parse(text);
            if (answer.error) { resolve({ status: null, headers: {}, body: null, error: answer.error }); return; }
            resolve({ status: answer.status, headers: answer.headers || {}, body: message.bytes ? fromBase64(answer.base64) : answer.text, error: null });
        };
        timer(poll, 0);
    });
}

// --- UI: sources can't open dialogs here; messages go to the log and the app's notice line --
let loadingIds = 1;
function ui(message) {
    switch (message.function) {
        case 'showMessage': manga('notice', { text: String(message.message ?? '') }); return null;
        case 'showDialog': manga('notice', { text: [message.title, message.content].filter(Boolean).join('\n') }); return Promise.resolve();
        case 'launchUrl': manga('notice', { url: String(message.url ?? '') }); return null;
        case 'showLoading': return loadingIds++;
        case 'cancelLoading': return null;
        case 'showInputDialog': case 'showSelectDialog': return Promise.resolve(null);
    }
    return null;
}

globalThis.sendMessage = function (message) {
    switch (message?.method) {
        case 'log': log(`[${message.level}] ${message.title}: ${typeof message.content === 'string' ? message.content : JSON.stringify(message.content)}`); return null;
        case 'delay': return new Promise(resolve => timer(resolve, Number(message.time) || 0));
        case 'http': return http(message);
        case 'html': return html(message);
        case 'convert':
            try { return convert(message); } catch (error) { log(`convert ${message.type}: ${error?.message || error}`); return null; }
        case 'random': {
            const min = message.min ?? 0, max = message.max ?? 1, value = min + (max - min) * Math.random();
            return message.type === 'double' ? value : Math.trunc(value);
        }
        case 'uuid': return manga('uuid');
        case 'cookie': return manga('cookie', { function: message.function, url: message.url, cookies: message.cookies });
        case 'load_data': return manga('data', { key: message.key, get: message.data_key });
        case 'save_data':
            if (message.data_key === 'setting') throw new Error('setting is not allowed to be saved');
            manga('data', { key: message.key, set: message.data_key, value: message.data ?? null }); return null;
        case 'delete_data': manga('data', { key: message.key, delete: message.data_key }); return null;
        case 'load_setting': {
            const saved = manga('data', { key: message.key, get: 'settings' });
            if (saved && saved[message.setting_key] != null) return saved[message.setting_key];
            // Defaults as the source declared them: some sources later overwrite `this.settings.x` with a value.
            return settingDefaults.get(message.key)?.[message.setting_key] ?? null;
        }
        case 'isLogged': return manga('data', { key: message.key, get: 'account' }) != null;
        case 'UI': return ui(message);
        case 'image': return manga('image', message);
        case 'getLocale': return manga('locale');
        case 'getPlatform': return manga('platform');
        case 'setClipboard': return Promise.resolve(null);
        case 'getClipboard': return Promise.resolve('');
        case 'compute': return new Promise((resolve, reject) => timer(() => {
            try { resolve((0, eval)(`(${message.function})`)(...(message.args || []))); } catch (error) { reject(error); }
        }, 0));
    }
    return null;
};

// --- Values crossing to Swift ---------------------------------------------------------------
// Maps keep their order as {"__map": [[key, value], ...]}; bytes travel as {"__bytes": base64}.
function plain(value, depth = 0) {
    if (depth > 40) return null;
    if (value == null || typeof value === 'number' || typeof value === 'string' || typeof value === 'boolean') return value ?? null;
    if (typeof value === 'bigint') return value.toString();
    if (typeof value === 'function' || typeof value === 'symbol') return null;
    if (value instanceof Map) return { __map: [...value].map(([k, v]) => [String(k), plain(v, depth + 1)]) };
    if (value instanceof Set) return [...value].map(v => plain(v, depth + 1));
    if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return { __bytes: toBase64(value) };
    if (Array.isArray(value)) return value.map(v => plain(v, depth + 1));
    if (value instanceof Date) return value.toISOString();
    // Swift's JSON reader forgets key order, which chapter lists depend on: `__keys` keeps it.
    const out = {}, keys = [];
    for (const key of Object.keys(value)) { const v = value[key]; if (typeof v !== 'function') { out[key] = plain(v, depth + 1); keys.push(key); } }
    if (keys.length > 1) out.__keys = keys;
    return out;
}
const failure = error => ({ error: String(error?.message ?? error ?? 'The source failed') });

let source;
const settingDefaults = new Map();
// Defaults Yingxia picks over a source's own. 拷贝漫画 limits each made-up device it is sent (status 210, "Expected
// available in N seconds"); a new device per request is the fix the open-source clients use (Venera's own switch for it,
// venera-configs#341, is off by default; RESTful-copymanga-api always rotates). 包子漫画's default domain (bzmgcn.com) now answers a browser check (403 challenge_required);
// its listed mirrors don't, so a mirror is the default. The viewer's own choice still wins.
const preferredDefaults = { copy_manga: { auto_clear_device_info: true }, baozi: { domains: "kukuc.co" } };
const declaredDefault = (key, name, item) => preferredDefaults[key]?.[name] ?? item?.default ?? null;
const configs = new Map();
let nextConfig = 1;
function lookup(path) {
    let owner, target = source;
    for (const part of path.split('.')) { owner = target; target = target?.[/^\d+$/.test(part) ? Number(part) : part]; }
    return { owner, target };
}
function describeOptions(list) {
    return (list || []).map(item => ({ type: item.type ?? 'select', label: item.label ?? '', default: plain(item.default ?? null),
        options: (item.options || []).map(String), showWhen: item.showWhen ?? null, notShowWhen: item.notShowWhen ?? null }));
}
function describe() {
    const s = source, has = path => typeof lookup(path).target === 'function';
    const category = s.category ? { title: s.category.title ?? '', enableRankingPage: !!s.category.enableRankingPage,
        parts: (s.category.parts || []).map(part => ({ name: part.name ?? '', type: part.type ?? 'fixed', itemType: part.itemType ?? 'category',
            categories: (part.categories || []).map(c => typeof c === 'object' ? String(c.label ?? c.title ?? c.name ?? '') : String(c)),
            categoryParams: part.categoryParams ?? (part.categories || []).map(c => typeof c === 'object' ? (c.target?.attributes?.param ?? c.param ?? null) : (part.groupParam ?? null)),
            randomNumber: part.randomNumber ?? null })) } : null;
    const settings = Object.entries(s.settings || {}).map(([key, item]) => ({ key, title: item.title ?? key, type: item.type ?? 'input',
        default: plain(declaredDefault(s.key, key, item)), options: (item.options || []).map(o => ({ value: String(o.value), text: String(o.text ?? o.value) })),
        validator: item.validator ?? null, buttonText: item.buttonText ?? null }));
    let locale = 'en';
    try { locale = APP.locale; } catch {}
    return {
        name: s.name, key: s.key, version: s.version, minAppVersion: s.minAppVersion ?? '', url: s.url ?? '',
        explore: (s.explore || []).map(page => ({ title: page.title ?? '', type: page.type ?? 'multiPageComicList', paged: typeof page.load === 'function' })),
        category,
        categoryComics: s.categoryComics ? { optionList: describeOptions(s.categoryComics.optionList),
            ranking: s.categoryComics.ranking ? { options: (s.categoryComics.ranking.options || []).map(String), paged: typeof s.categoryComics.ranking.load === 'function' } : null } : null,
        search: s.search ? { optionList: describeOptions(s.search.optionList), paged: typeof s.search.load === 'function' } : null,
        comic: { thumbnails: has('comic.loadThumbnails'), comments: has('comic.loadComments'), imageConfig: has('comic.onImageLoad'),
            thumbnailConfig: has('comic.onThumbnailLoad'), idMatch: s.comic?.idMatch ?? null, clickTag: has('comic.onClickTag') },
        account: s.account ? { login: has('account.login'), cookieFields: s.account.loginWithCookies?.fields ?? null,
            webview: s.account.loginWithWebview?.url ?? null, register: s.account.registerWebsite ?? null } : null,
        favorites: s.favorites ? { multiFolder: !!s.favorites.multiFolder } : null,
        settings, translation: plain(s.translation?.[locale] ?? s.translation?.[locale.split('_')[0]] ?? null),
    };
}

globalThis.__venera = {
    // Instantiates the source the way Venera does: the first `class X extends ComicSource` line names it.
    async load(code) {
        try {
            const line = code.replace(/\r\n/g, '\n').split('\n').find(text => text.trim().startsWith('class '));
            const match = line && /class\s+([A-Za-z0-9_$]+)\s+extends\s+ComicSource/.exec(line);
            if (!match) throw new Error('This is not a Venera comic source');
            source = (0, eval)(`(() => {\n${code}\n;return new ${match[1]}();\n})()`);
            if (!source?.key || !/^[A-Za-z0-9_]+$/.test(source.key)) throw new Error('The source has no valid key');
            ComicSource.sources[source.key] = source;
            settingDefaults.set(source.key, Object.fromEntries(Object.entries(source.settings || {}).map(([key, item]) => [key, declaredDefault(source.key, key, item)])));
            if (typeof source.init === 'function') {
                try { await source.init(); } catch (error) { log(`init failed: ${error?.message || error}`); }
            }
            return { value: describe() };
        } catch (error) { return failure(error); }
    },
    describe() { try { return { value: describe() }; } catch (error) { return failure(error); } },
    // Calls the source's function at `path` ("comic.loadInfo", "explore.0.load", ...).
    async call(path, args) {
        try {
            const { owner, target } = lookup(path);
            if (typeof target !== 'function') throw new Error(`The source has no ${path}`);
            return { value: plain(await target.apply(owner, args || [])) };
        } catch (error) { return failure(error); }
    },
    // Image loading configs: functions stay here, Swift gets the data and an id to call them by.
    async imageConfig(kind, url, comicId, epId) {
        try {
            const path = kind === 'thumbnail' ? 'comic.onThumbnailLoad' : 'comic.onImageLoad';
            const { owner, target } = lookup(path);
            const config = typeof target === 'function' ? (await target.apply(owner, kind === 'thumbnail' ? [url] : [url, comicId, epId])) ?? {} : {};
            const id = nextConfig++;
            configs.set(id, config);
            while (configs.size > 400) configs.delete(configs.keys().next().value);
            const headers = {};
            for (const [name, value] of Object.entries(config.headers || {})) if (value != null) headers[name] = String(value);
            return { value: { id, url: config.url ?? url, method: String(config.method || 'GET').toUpperCase(), headers,
                body: requestBody(config.data, headers), onResponse: typeof config.onResponse === 'function',
                modifyImage: typeof config.modifyImage === 'string' && config.modifyImage.trim() ? true : false,
                onLoadFailed: typeof config.onLoadFailed === 'function' } };
        } catch (error) { return failure(error); }
    },
    async thumbnailHeaders(urls) {
        const out = {};
        for (const url of urls) {
            const answer = await this.imageConfig('thumbnail', url);
            if (answer.value) { out[url] = { url: answer.value.url, headers: answer.value.headers }; configs.delete(answer.value.id); }
        }
        return { value: out };
    },
    async onResponse(id, base64) {
        try {
            const result = await configs.get(id).onResponse(fromBase64(base64));
            return { value: toBase64(result) };
        } catch (error) { return failure(error); }
    },
    async onLoadFailed(id) {
        try {
            const config = await configs.get(id).onLoadFailed();
            configs.set(id, config ?? {});
            return { value: config?.url ? { url: config.url, headers: config.headers || {} } : null };
        } catch (error) { return failure(error); }
    },
    // Runs the config's `modifyImage` script on a native image (MangaHost's image store).
    modify(id, key) {
        try {
            const script = configs.get(id)?.modifyImage;
            const run = (0, eval)(`(() => {\n${script}\n;return modifyImage;\n})()`);
            const result = run(new Image(key));
            return { value: result?.key ?? key };
        } catch (error) { return failure(error); }
    },
    release(id) { configs.delete(id); return { value: true }; },
};
