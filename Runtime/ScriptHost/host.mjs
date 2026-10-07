import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

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
    if (error.remote) return { error: error.message, errorCode: error.status ? 'source_http' : 'source_network', host: error.remote, status: error.status };
    return { error: String(error), errorCode: 'script_error' };
}
function remoteError(host, status, message) { return Object.assign(new Error(message), { remote: host, status }); }

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
    const id = crypto.randomUUID();
    const headerFile = path.join(cache, id + '.headers');
    const bodyFile = path.join(cache, id + '.body');
    const timeout = Math.max(1, Math.min(30, Number(options.timeout || 20000) / 1000));
    const method = String(options.method || 'GET').toUpperCase();
    if (!/^[A-Z]+$/.test(method)) throw new Error('Invalid HTTP method');
    const args = ['--silent', '--show-error', '--compressed', '--proto', '=http,https', '--proto-redir', '=http,https', '--max-redirs', '5', '--max-time', String(timeout), '--max-filesize', '20000000', '--dump-header', headerFile, '--output', bodyFile, '--write-out', '%{http_code}\n%{url_effective}', '--request', method === 'HEADER' ? 'HEAD' : method];
    if (options.redirect !== 0 && options.redirect !== false) args.push('--location');
    let headers = { ...(options.headers || options.header || {}) };
    if (!Object.keys(headers).some(key => key.toLowerCase() === 'user-agent')) headers['User-Agent'] = 'Mozilla/5.0';
    let body = options.body;
    if (options.data != null) {
        if (options.postType === 'json') { body = JSON.stringify(options.data); headers['Content-Type'] ||= 'application/json'; }
        else { body = new URLSearchParams(options.data).toString(); headers['Content-Type'] ||= 'application/x-www-form-urlencoded'; }
    }
    for (const [key, value] of Object.entries(headers)) {
        if (/[\r\n]/.test(key + value)) throw new Error('Invalid HTTP header');
        // curl drops "Name: " with an empty value; "Name;" sends it empty.
        args.push('--header', String(value) === '' ? key + ';' : key + ': ' + String(value));
    }
    // `bodyBase64` carries binary request bodies (for example protobuf) that a string would corrupt.
    const input = options.bodyBase64 != null ? Buffer.from(String(options.bodyBase64), 'base64') : body == null ? undefined : String(body);
    if (input !== undefined && method !== 'GET' && method !== 'HEAD') args.push('--data-binary', '@-');
    args.push('--url', url.href);
    try {
        const result = spawnSync('/usr/bin/curl', args, { input, encoding: 'utf8', timeout: (timeout + 2) * 1000, maxBuffer: 1024 * 1024 });
        if (result.status !== 0) throw remoteError(url.host, 0, 'Network request failed: ' + (result.stderr || result.error || result.status));
        const [status, effective] = result.stdout.split('\n');
        const code = Number(status);
        const blocks = fs.readFileSync(headerFile, 'utf8').trim().split(/\r?\n\r?\n/);
        const responseHeaders = {};
        for (const line of (blocks.at(-1) || '').split(/\r?\n/).slice(1)) {
            const colon = line.indexOf(':');
            if (colon < 1) continue;
            const name = line.slice(0, colon).toLowerCase(), value = line.slice(colon + 1).trim();
            responseHeaders[name] = responseHeaders[name] === undefined ? value : [].concat(responseHeaders[name], value);
        }
        const bytes = fs.readFileSync(bodyFile);
        if (bytes.length > 20_000_000) throw new Error('Script response exceeded 20 MB');
        let content;
        if (options.buffer === 1) content = Array.from(bytes);
        else if (options.buffer === 2) content = bytes.toString('base64');
        else if (options.buffer === 3) content = new Uint8Array(bytes);
        else content = new TextDecoder(options.encoding || 'utf-8').decode(bytes);
        log('SCRIPT_HTTP', url.host + url.pathname, code);
        if (code >= 400) lastFailure = remoteError(url.host, code, `The source ${url.host} returned HTTP ${code}`);
        else if (lastFailure?.remote === url.host) lastFailure = undefined;
        const response = { code, headers: responseHeaders, content, url: effective || url.href };
        if (typeof options.complete === 'function') options.complete(response);
        return response;
    } catch (error) {
        lastFailure = error.remote ? error : remoteError(url.host, 0, String(error));
        log('SCRIPT_HTTP_FAILED', url.host, error.message);
        const response = { code: 0, headers: {}, content: '', url: url.href };
        if (typeof options.complete === 'function') options.complete(response);
        return response;
    } finally {
        fs.rmSync(headerFile, { force: true }); fs.rmSync(bodyFile, { force: true });
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
try {
    const spider = await initialize();
    if (serving) {
        writeJSON(path.join(cache, 'ready.json'), { ready: true });
        for await (const line of readline.createInterface({ input: process.stdin })) {
            const command = JSON.parse(line);
            if (!/^[A-Za-z0-9-]{1,80}$/.test(command.id)) throw new Error('Invalid request identifier');
            let response;
            try { response = await call(spider, command.params); } catch (error) { response = envelope(error); }
            writeJSON(path.join(cache, 'responses', command.id + '.json'), response);
        }
    } else process.stdout.write(JSON.stringify(await call(spider, input.params)) + '\n');
    process.exit(0);
} catch (error) {
    const response = envelope(error);
    if (serving) writeJSON(path.join(cache, 'ready.json'), response);
    else process.stdout.write(JSON.stringify(response) + '\n');
    process.exit(1);
}
