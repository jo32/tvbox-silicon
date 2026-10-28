import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import { createRequire } from 'node:module';
import zlib from 'node:zlib';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { Worker, MessageChannel, receiveMessageOnPort } from 'node:worker_threads';

const serving = process.argv[2] === '--serve';
const input = JSON.parse(fs.readFileSync(process.argv[serving ? 3 : 2], 'utf8'));
const cache = input.cache;
const profile = input.profile || path.join(cache, 'profile');
const assets = path.join(path.dirname(fileURLToPath(import.meta.url)), 'assets');
fs.mkdirSync(profile, { recursive: true });
fs.mkdirSync(path.join(cache, 'responses'), { recursive: true });
const prefsFile = path.join(profile, 'preferences.json');
let preferences = {};
try { preferences = JSON.parse(fs.readFileSync(prefsFile, 'utf8')); } catch { }
let lastFailure;
function writeJSON(file, object) {
    fs.writeFileSync(file + '.tmp', JSON.stringify(object));
    fs.renameSync(file + '.tmp', file);
}
function log(...values) { process.stderr.write(values.map(v => typeof v === 'string' ? v : JSON.stringify(v)).join(' ') + '\n'); }
function envelope(error) {
    log(error.stack || error.message || error);
    // A spider that parses a failed response (an HTML error page, an empty body) throws a SyntaxError.
    // The failed request is the real cause, so report it instead (by name: spiders may run in another realm).
    if (error?.name === 'SyntaxError' && lastFailure) error = lastFailure;
    if (error.remote) return { error: error.message, errorCode: error.status ? 'source_http' : 'source_network', host: error.remote, status: error.status };
    return { error: String(error), errorCode: 'script_error' };
}
function remoteError(host, status, message) { return Object.assign(new Error(message), { remote: host, status }); }

// Spiders and the module loader call HTTP synchronously (drpy's `http(url, {async: false})`,
// `sourceFor`). Node has no synchronous `fetch`, so the real `fetch` runs on a worker thread and
// this thread blocks on it with `Atomics.wait`, then drains the reply with `receiveMessageOnPort`.
// This keeps HTTP in-process with no child process, so the macOS sandbox can deny all exec.
const fetchWorkerSource = `
'use strict';
const { parentPort, workerData } = require('node:worker_threads');
const { port, shared } = workerData;
const signal = new Int32Array(shared);
function wake(message) { port.postMessage(message); Atomics.store(signal, 0, 1); Atomics.notify(signal, 0); }
parentPort.on('message', async (req) => {
    try {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), req.timeout + 2000);
        const init = { method: req.method, headers: req.headers, redirect: req.redirect, signal: controller.signal };
        if (req.bodyBase64 !== undefined) init.body = Buffer.from(req.bodyBase64, 'base64');
        const response = await fetch(req.url, init);
        const chunks = []; let total = 0; let overflow = false;
        if (response.body) {
            const reader = response.body.getReader();
            for (;;) {
                const { done, value } = await reader.read();
                if (done) break;
                total += value.byteLength;
                if (total > 20000000) { overflow = true; controller.abort(); break; }
                chunks.push(Buffer.from(value.buffer, value.byteOffset, value.byteLength));
            }
        }
        clearTimeout(timer);
        const headers = {};
        for (const [name, value] of response.headers) {
            if (name.toLowerCase() === 'set-cookie') continue;
            const key = name.toLowerCase();
            headers[key] = headers[key] === undefined ? value : [].concat(headers[key], value);
        }
        const cookies = typeof response.headers.getSetCookie === 'function' ? response.headers.getSetCookie() : [];
        if (cookies.length) headers['set-cookie'] = cookies.length === 1 ? cookies[0] : cookies;
        if (overflow) { wake({ error: 'Script response exceeded 20 MB' }); return; }
        wake({ status: response.status, url: response.url, headers, bodyBase64: Buffer.concat(chunks).toString('base64') });
    } catch (error) {
        wake({ error: String((error && error.message) || error) });
    }
});
`;
const fetchChannel = new MessageChannel();
const fetchSignal = new Int32Array(new SharedArrayBuffer(4));
const fetchWorker = new Worker(fetchWorkerSource, { eval: true, workerData: { port: fetchChannel.port2, shared: fetchSignal.buffer }, transferList: [fetchChannel.port2] });
fetchWorker.unref();
let fetchWorkerError;
fetchWorker.on('error', error => { fetchWorkerError = error; Atomics.store(fetchSignal, 0, 1); Atomics.notify(fetchSignal, 0); });
function syncFetch(request) {
    if (fetchWorkerError) throw fetchWorkerError;
    Atomics.store(fetchSignal, 0, 0);
    fetchWorker.postMessage(request);
    Atomics.wait(fetchSignal, 0, 0);
    if (fetchWorkerError) throw fetchWorkerError;
    const message = receiveMessageOnPort(fetchChannel.port1);
    if (!message) throw new Error('The fetch worker returned no response');
    return message.message;
}

/** Native AES/hash/HMAC, as ScriptCrypto.swift on QuickJS. Binary fields are base64. */
function nativeCrypto(request) {
    const bytes = name => request[name + 'Text'] != null ? Buffer.from(String(request[name + 'Text']), 'utf8')
        : request[name + 'Hex'] != null ? Buffer.from(String(request[name + 'Hex']), 'hex') : Buffer.from(String(request[name] || ''), 'base64');
    const alg = String(request.alg || '').toLowerCase();
    if (request.op === 'aes') {
        const key = bytes('key'), ecb = String(request.mode || '').toUpperCase() === 'ECB';
        const name = `aes-${key.length * 8}-${ecb ? 'ecb' : 'cbc'}`;
        const cipher = (request.encrypt ? crypto.createCipheriv : crypto.createDecipheriv)(name, key, ecb ? null : bytes('iv'));
        cipher.setAutoPadding(request.padding !== false);
        const result = Buffer.concat([cipher.update(bytes('data')), cipher.final()]);
        if (request.output === 'hex') return { hex: result.toString('hex') };
        if (request.output === 'text') return { text: result.toString('utf8') };
        return { data: result.toString('base64') };
    }
    if (request.op === 'inflate') {
        const result = request.raw ? zlib.inflateRawSync(bytes('data')) : zlib.inflateSync(bytes('data'));
        if (request.output === 'hex') return { hex: result.toString('hex') };
        if (request.output === 'base64') return { data: result.toString('base64') };
        return { text: result.toString('utf8') };
    }
    if (request.op === 'hash') return { hex: crypto.createHash(alg).update(bytes('data')).digest('hex') };
    if (request.op === 'hmac') return { hex: crypto.createHmac(alg, bytes('key')).update(bytes('data')).digest('hex') };
    if (request.op === 'pow') {
        // First nonce whose hex digest of prefix+nonce starts with / equals target (ScriptCrypto.proofOfWork).
        const target = String(request.target || '').toLowerCase(), prefix = String(request.prefix || '');
        const end = Number(request.end ?? 2100000), deadline = Date.now() + Number(request.limitMs ?? 20000);
        for (let nonce = Number(request.start || 0); target && nonce <= end; nonce++) {
            const hex = crypto.createHash(alg === 'md5' ? 'md5' : 'sha256').update(prefix + nonce).digest('hex');
            if (request.match === 'equal' ? hex === target : hex.startsWith(target)) return { nonce: String(nonce) };
            if ((nonce & 1023) === 0 && Date.now() > deadline) break;
        }
        return { nonce: '' };
    }
    throw new Error('unsupported crypto operation');
}

function request(address, options = {}) {
    const url = new URL(String(address));
    if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Only HTTP and HTTPS script requests are supported');
    const timeout = Math.max(1000, Math.min(30000, Number(options.timeout || 20000)));
    const method = String(options.method || 'GET').toUpperCase();
    if (!/^[A-Z]+$/.test(method)) throw new Error('Invalid HTTP method');
    let headers = { ...(options.headers || options.header || {}) };
    if (!Object.keys(headers).some(key => key.toLowerCase() === 'user-agent')) headers['User-Agent'] = 'Mozilla/5.0';
    let body = options.body;
    if (options.data != null) {
        if (options.postType === 'json') { body = JSON.stringify(options.data); headers['Content-Type'] ||= 'application/json'; }
        else { body = new URLSearchParams(options.data).toString(); headers['Content-Type'] ||= 'application/x-www-form-urlencoded'; }
    }
    const sendHeaders = {};
    for (const [key, value] of Object.entries(headers)) {
        if (/[\r\n]/.test(key + value)) throw new Error('Invalid HTTP header');
        sendHeaders[key] = String(value);
    }
    // `bodyBase64` carries binary request bodies (for example protobuf) that a string would corrupt.
    const bodyBase64 = options.bodyBase64 != null ? String(options.bodyBase64)
        : body == null ? undefined : Buffer.from(String(body), 'utf8').toString('base64');
    const sendMethod = method === 'HEADER' ? 'HEAD' : method;
    try {
        const result = syncFetch({
            url: url.href,
            method: sendMethod,
            headers: sendHeaders,
            bodyBase64: (sendMethod === 'GET' || sendMethod === 'HEAD') ? undefined : bodyBase64,
            // `fetch` only ever follows http(s) redirects; 'manual' returns the 3xx untouched.
            redirect: (options.redirect !== 0 && options.redirect !== false) ? 'follow' : 'manual',
            timeout
        });
        if (result.error) throw remoteError(url.host, 0, 'Network request failed: ' + result.error);
        const code = result.status;
        const responseHeaders = result.headers || {};
        const bytes = Buffer.from(result.bodyBase64 || '', 'base64');
        if (bytes.length > 20_000_000) throw new Error('Script response exceeded 20 MB');
        let content;
        if (options.buffer === 1) content = Array.from(bytes);
        else if (options.buffer === 2) content = bytes.toString('base64');
        else if (options.buffer === 3) content = new Uint8Array(bytes);
        else content = new TextDecoder(options.encoding || 'utf-8').decode(bytes);
        log('SCRIPT_HTTP', url.host + url.pathname, code);
        if (code >= 400) lastFailure = remoteError(url.host, code, `The source ${url.host} returned HTTP ${code}`);
        else if (lastFailure?.remote === url.host) lastFailure = undefined;
        const response = { code, headers: responseHeaders, content, url: result.url || url.href };
        if (typeof options.complete === 'function') options.complete(response);
        return response;
    } catch (error) {
        lastFailure = error.remote ? error : remoteError(url.host, 0, String(error));
        log('SCRIPT_HTTP_FAILED', url.host, error.message);
        const response = { code: 0, headers: {}, content: '', url: url.href };
        if (typeof options.complete === 'function') options.complete(response);
        return response;
    }
}

const local = {
    get(group, key) { return preferences[JSON.stringify([group, key])] || ''; },
    set(group, key, value) { preferences[JSON.stringify([group, key])] = String(value); writeJSON(prefsFile, preferences); },
    delete(group, key) { delete preferences[JSON.stringify([group, key])]; writeJSON(prefsFile, preferences); }
};
const globals = {
    console: { log, info: log, warn: log, error: log, debug: log }, print: log, log,
    req: request, _http: request, fetch: request,
    http: (url, options = {}) => options.async === false ? request(url, options) : Promise.resolve(request(url, options)),
    local, URL, URLSearchParams, TextEncoder, TextDecoder, Buffer, crypto: crypto.webcrypto,
    setTimeout, clearTimeout, setInterval, clearInterval,
    joinUrl: (parent, child) => new URL(child, parent).href,
    base64Encode: text => Buffer.from(String(text)).toString('base64'),
    base64Decode: text => Buffer.from(String(text), 'base64').toString('utf8'),
    btoa: text => Buffer.from(String(text), 'latin1').toString('base64'),
    atob: text => Buffer.from(String(text), 'base64').toString('latin1'),
    md5X: text => crypto.createHash('md5').update(String(text)).digest('hex'),
    nativeCrypto,
    gzip: text => zlib.gzipSync(Buffer.from(String(text))).toString('base64'),
    ungzip: text => zlib.gunzipSync(Buffer.from(String(text), 'base64')).toString('utf8'),
    getProxy: () => 'http://127.0.0.1:-1/proxy?do=js', getPort: () => -1,
    s2t: text => text, t2s: text => text
};
const context = vm.createContext(globals);
// Scripts assign the undeclared global `__JS_SPIDER__`, which strict module code allows only once it exists.
vm.runInContext('globalThis.global = globalThis; globalThis.window = globalThis; globalThis.self = globalThis; globalThis.__JS_SPIDER__ = undefined;', context);
const modules = new Map();
// Widely shared drpy2 builds import their helper libraries from a qu.ax mirror that no longer
// serves them. They are drpy's standard bundled libraries, so load the bundled copies instead.
const retiredLibraries = { 'cLFE.js': 'jsencrypt.js', 'kOUW.js': 'node-rsa.js', 'ucoN.js': 'pako.min.js', 'XUKQ.js': '模板.js', 'wYCz.js': 'gbk.js' };
function moduleURL(specifier, parent) {
    if (specifier.startsWith('lib/')) return 'assets://js/' + specifier;
    const url = new URL(specifier, parent).href;
    const retired = url.match(/\/qu\.ax\/(\w+\.js)$/);
    if (retired && retiredLibraries[retired[1]]) return 'assets://js/lib/' + retiredLibraries[retired[1]];
    return url;
}
function sourceFor(url) {
    if (url === input.api) return fs.readFileSync(input.script, 'utf8');
    if (url.startsWith('assets://')) {
        const relative = url.slice('assets://'.length);
        const file = path.resolve(assets, relative);
        if (!file.startsWith(assets + path.sep)) throw new Error('Invalid asset path');
        return fs.readFileSync(file, 'utf8');
    }
    if (!/^https?:/.test(url)) throw new Error('Unsupported module URL: ' + url);
    const folder = path.join(profile, 'modules'); fs.mkdirSync(folder, { recursive: true });
    const file = path.join(folder, crypto.createHash('sha256').update(url).digest('hex') + '.js');
    if (fs.existsSync(file) && Date.now() - fs.statSync(file).mtimeMs < 300_000) return fs.readFileSync(file, 'utf8');
    const response = request(url);
    if (response.code < 200 || response.code >= 300) throw lastFailure || new Error('Cannot load module ' + url);
    fs.writeFileSync(file, response.content); return response.content;
}
function getModule(url) {
    if (modules.has(url)) return modules.get(url);
    const source = sourceFor(url);
    const module = new vm.SourceTextModule(source, {
        context, identifier: url,
        initializeImportMeta(meta) { meta.url = url; },
        importModuleDynamically: async (specifier, reference) => {
            const dependency = getModule(moduleURL(specifier, reference.identifier));
            if (dependency.status === 'unlinked') await dependency.link(linker);
            if (dependency.status === 'linked') await dependency.evaluate({ timeout: 20_000 });
            return dependency;
        }
    });
    modules.set(url, module); return module;
}
const linker = (specifier, reference) => getModule(moduleURL(specifier, reference.identifier));
async function initialize() {
    const parser = getModule('assets://js/lib/cheerio.min.js');
    await parser.link(linker); await parser.evaluate({ timeout: 20_000 });
    context.__cheerio = parser.namespace;
    vm.runInContext(`
        function selectNodes(html, expression, single) {
            const $ = __cheerio.load(String(html));
            let node = $.root();
            for (const selector of expression.split('&&').filter(Boolean)) {
                node = node.find(selector.trim());
                if (single) node = node.first();
            }
            return {$, node};
        }
        globalThis.pdfh = function(html, expression) {
            const parts = expression.split('&&');
            const attribute = parts.pop();
            const {node} = selectNodes(html, parts.join('&&'), true);
            if (attribute === 'Text') return node.text().trim();
            if (attribute === 'Html') return node.html() || '';
            return node.attr(attribute) || '';
        };
        globalThis.pdfa = function(html, expression) {
            const {$, node} = selectNodes(html, expression, false);
            return node.toArray().map(element => $.html(element));
        };
        globalThis.pd = function(html, expression, base) {
            const value = pdfh(html, expression);
            try { return new URL(value, base).href; } catch { return value; }
        };
    `, context);

    const module = getModule(input.api);
    await module.link(linker); await module.evaluate({ timeout: 20_000 });
    const namespace = module.namespace;
    let spider = context.__JS_SPIDER__;
    let extension = input.ext || '';
    if (namespace.__jsEvalReturn) {
        spider ||= namespace.__jsEvalReturn();
        extension = { stype: 3, skey: input.key, ext: extension };
    } else if (!spider) spider = typeof namespace.default === 'function' ? namespace.default() : namespace.default;
    if (!spider) throw new Error('The script exports no spider');
    if (typeof spider.init === 'function') await spider.init(extension);
    return spider;
}
async function call(spider, params) {
    lastFailure = undefined;
    let method, args;
    if ('play' in params) { method = 'play'; args = [params.flag || '', params.play, []]; }
    else if ('ids' in params) { method = 'detail'; args = [params.ids]; }
    else if ('wd' in params) { method = 'search'; args = [params.wd, false, params.pg || '1']; }
    else if ('t' in params) { method = 'category'; args = [params.t, params.pg || '1', true, {}]; }
    else { method = 'home'; args = [true]; }
    if (typeof spider[method] !== 'function') throw new Error(`The script does not implement ${method}`);
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
}
// CatPawOpen bundles (猫源) are Node servers in the CatVod Open format: `start(config)` builds a Fastify app
// on the server `catServerFactory` makes, the app lists its sources at GET /config and serves each at
// POST /spider/<key>/<type>/{init,home,category,detail,play,search}. The server only listens on loopback.
let catServer, catProxyTouched = 0;
const catStarted = new Set();
async function startCatPaw() {
    process.env.NODE_ENV = 'development'; // Fastify then skips its per-request logger
    process.env.NODE_PATH = profile; // where the bundle keeps its settings database
    // Bundles log with console.log; stdout carries the one-shot answer, so their logs join the host's on stderr.
    Object.assign(console, { log, info: log, warn: log, error: log, debug: log });
    // Some bundles' handlers answer a request twice; the CatVod apps keep serving, so this does too.
    process.on('uncaughtException', error => log('CATPAW_UNCAUGHT', error?.stack || String(error)));
    globalThis.catDartServerPort = () => 0;
    globalThis.catServerFactory = handler => {
        catServer = http.createServer((req, res) => {
            // Anything but the host's own calls is the player reading the bundle's media proxy.
            if (!req.headers['x-yingxia-host'] && Date.now() - catProxyTouched > 5000) {
                catProxyTouched = Date.now();
                fs.writeFileSync(path.join(cache, 'proxy-active'), '');
            }
            handler(req, res);
        });
        const listen = catServer.listen.bind(catServer);
        catServer.listen = (...args) => listen(0, '127.0.0.1', args.find(arg => typeof arg === 'function'));
        return catServer;
    };
    const require = createRequire(input.script);
    // The bundle's settings sit beside it (index.js -> index.config.js); without them it starts with none.
    let config = {};
    const configResponse = request(new URL(input.api.replace(/\.js(?=$|[?#])/, '.config.js')).href);
    if (configResponse.code >= 200 && configResponse.code < 300 && configResponse.content) {
        const file = path.join(cache, 'index.config.js');
        fs.writeFileSync(file, configResponse.content);
        try { const module = require(file); config = module?.default ?? module ?? {}; } catch (error) { log('CATPAW_CONFIG', error.message); }
    }
    const bundle = require(input.script);
    if (typeof bundle.start !== 'function') throw new Error('The script is not a CatPawOpen bundle');
    await bundle.start(config);
    const deadline = Date.now() + 20_000;
    while (!catServer?.listening) {
        if (Date.now() > deadline) throw new Error('The CatPawOpen server did not start');
        await new Promise(resolve => setTimeout(resolve, 50));
    }
}
// The app's cloud-drive sign-ins, for bundles that keep their own and sign in through a config center the app can't
// show. Bundles of the wexfnw family take them at PUT /website/api/credential/<drive>/cookie. Each sign-in passes on
// once per change in the app, so the bundle's own refreshes of it stay. Keep in step with NodeHost/main.mjs.
const sharedDrives = { quark: 'quarkCookie', uc: 'ucCookie', baidu: 'baiduCookie' };
let catTakesAccounts = true, catAccountsStamp;
async function shareCatPawAccounts(port) {
    if (!input.cloudAccounts || !catTakesAccounts) return;
    let stamp;
    try { stamp = fs.statSync(input.cloudAccounts).mtimeMs; } catch { return; }
    if (stamp === catAccountsStamp) return;
    catAccountsStamp = stamp;
    const accounts = JSON.parse(fs.readFileSync(input.cloudAccounts, 'utf8'));
    const givenFile = path.join(profile, 'yingxia-accounts.json');
    let given = {};
    try { given = JSON.parse(fs.readFileSync(givenFile, 'utf8')); } catch { }
    const digest = text => crypto.createHash('sha256').update(text).digest('hex');
    let changed = false;
    for (const [drive, key] of Object.entries(sharedDrives)) {
        const cookie = String(accounts[key] || '').trim();
        if (!cookie || given[drive] === digest(cookie)) continue;
        const response = await fetch(`http://127.0.0.1:${port}/website/api/credential/${drive}/cookie`, {
            method: 'PUT', headers: { 'x-yingxia-host': '1', 'content-type': 'application/json' }, body: JSON.stringify({ value: cookie }),
        });
        // The config center answers {code: 0}; anything else is a bundle without one.
        let saved = false;
        try { saved = response.ok && JSON.parse(await response.text()).code === 0; } catch { }
        if (!saved) { catTakesAccounts = false; break; }
        given[drive] = digest(cookie); changed = true; log('CATPAW_ACCOUNT', drive);
    }
    if (changed) writeJSON(givenFile, given);
}
async function callCatPaw(params) {
    const port = catServer.address().port;
    await shareCatPawAccounts(port).catch(error => log('CATPAW_ACCOUNT', error?.stack || String(error)));
    const send = async (route, body) => {
        const headers = { 'x-yingxia-host': '1' };
        const init = body === undefined ? { headers } : { method: 'POST', headers: { ...headers, 'content-type': 'application/json' }, body: JSON.stringify(body) };
        const response = await fetch(`http://127.0.0.1:${port}${route}`, init);
        const text = await response.text();
        if (!response.ok) {
            let message = text;
            try { message = JSON.parse(text).message || text; } catch { }
            throw new Error(`The source failed (HTTP ${response.status}): ${String(message).slice(0, 300)}`);
        }
        return text;
    };
    if (params.catConfig) return { result: await send('/config') };
    const api = String(params.catPawOpen || '');
    if (!/^\/spider\/[^?#]+$/.test(api)) throw new Error('Invalid CatPawOpen source');
    if (!catStarted.has(api)) { await send(api + '/init', {}); catStarted.add(api); }
    let route, body;
    if ('play' in params) { route = '/play'; body = { flag: params.flag || '', id: params.play }; }
    else if ('ids' in params) { route = '/detail'; body = { id: params.ids }; }
    else if ('wd' in params) { route = '/search'; body = { wd: params.wd, page: Number(params.pg || 1), quick: params.quick === 'true' }; }
    else if ('t' in params) { route = '/category'; body = { id: params.t, page: Number(params.pg || 1), filter: true, filters: {} }; }
    else { route = '/home'; body = {}; }
    const result = await send(api + route, body);
    // Sources address the bundle's own proxy by the Mac's network address, but the server is on loopback.
    return { result: result.replace(new RegExp(`http://\\d+\\.\\d+\\.\\d+\\.\\d+:${port}/`, 'g'), `http://127.0.0.1:${port}/`) };
}
try {
    const spider = input.catPawOpen ? await startCatPaw() : await initialize();
    const answer = params => input.catPawOpen ? callCatPaw(params) : call(spider, params);
    if (serving) {
        writeJSON(path.join(cache, 'ready.json'), { ready: true });
        for await (const line of readline.createInterface({ input: process.stdin })) {
            const command = JSON.parse(line);
            if (!/^[A-Za-z0-9-]{1,80}$/.test(command.id)) throw new Error('Invalid request identifier');
            let response;
            try { response = await answer(command.params); } catch (error) { response = envelope(error); }
            writeJSON(path.join(cache, 'responses', command.id + '.json'), response);
        }
    } else process.stdout.write(JSON.stringify(await answer(input.params)) + '\n');
    process.exit(0);
} catch (error) {
    const response = envelope(error);
    if (serving) writeJSON(path.join(cache, 'ready.json'), response);
    else process.stdout.write(JSON.stringify(response) + '\n');
    process.exit(1);
}
