// CatPawOpen (猫源) bundles on iPhone and iPad. EmbeddedNodeHost starts this once in the app's nodejs-mobile
// and calls it over loopback: POST /call {bundle, api, profile, params} with the token it writes beside its
// port. It mirrors the CatPawOpen mode of Runtime/ScriptHost/host.mjs (the Mac's sandboxed host); keep them in step.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const controlFile = process.argv[2];
const token = crypto.randomBytes(16).toString('hex');
function log(...values) { process.stderr.write(values.map(v => typeof v === 'string' ? v : JSON.stringify(v)).join(' ') + '\n'); }
process.env.NODE_ENV = 'development'; // Fastify then skips its per-request logger
Object.assign(console, { log, info: log, warn: log, error: log, debug: log });
// Some bundles' handlers answer a request twice; the CatVod apps keep serving, so this does too.
process.on('uncaughtException', error => log('CATPAW_UNCAUGHT', error?.stack || String(error)));
process.on('unhandledRejection', error => log('CATPAW_UNHANDLED', error?.stack || String(error)));
globalThis.catDartServerPort = () => 0;

// nodejs-mobile's V8 runs without a JIT, so it has no WebAssembly, and Node 18's fetch (undici) needs it.
function request(url, { method = 'GET', headers = {}, body, timeout = 60_000 } = {}, redirects = 5) {
    return new Promise((resolve, reject) => {
        const target = new URL(url);
        if (body !== undefined) headers = { ...headers, 'content-length': Buffer.byteLength(body) };
        const req = (target.protocol === 'https:' ? https : http).request(target, { method, headers, timeout }, res => {
            if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
                res.resume();
                resolve(request(new URL(res.headers.location, target).href, { method, headers, body, timeout }, redirects - 1));
                return;
            }
            const chunks = [];
            res.on('data', chunk => chunks.push(chunk));
            res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
            res.on('error', reject);
        });
        req.on('timeout', () => req.destroy(new Error(`${target.host} did not answer in time`)));
        req.on('error', reject);
        req.end(body);
    });
}

// A bundle's `start(config)` builds a Fastify app on the server `catServerFactory` makes, then lists its
// sources at GET /config and serves each at POST /spider/<key>/<type>/{init,home,category,detail,play,search}.
const bundles = new Map(); // bundle file -> Promise<{port, started}>
let starting = Promise.resolve();
async function start({ bundle, api, profile }) {
    let server;
    globalThis.catServerFactory = handler => {
        server = http.createServer(handler);
        const listen = server.listen.bind(server);
        server.listen = (...args) => listen(0, '127.0.0.1', args.find(arg => typeof arg === 'function'));
        return server;
    };
    fs.mkdirSync(profile, { recursive: true });
    process.env.NODE_PATH = profile; // where the bundle keeps its settings database
    const require = createRequire(bundle);
    // The bundle's settings sit beside it (index.js -> index.config.js); without them it starts with none.
    let config = {};
    try {
        const response = await request(api.replace(/\.js(?=$|[?#])/, '.config.js'), { timeout: 20_000 });
        const text = response.status === 200 ? response.text : '';
        if (text) {
            const file = bundle.replace(/\.js$/, '.config.js');
            fs.writeFileSync(file, text);
            delete require.cache[file];
            const module = require(file);
            config = module?.default ?? module ?? {};
        }
    } catch (error) { log('CATPAW_CONFIG', error.message); }
    const exports = require(bundle);
    if (typeof exports.start !== 'function') throw new Error('The script is not a CatPawOpen bundle');
    await exports.start(config);
    const deadline = Date.now() + 20_000;
    while (!server?.listening) {
        if (Date.now() > deadline) throw new Error('The CatPawOpen server did not start');
        await new Promise(resolve => setTimeout(resolve, 50));
    }
    return { port: server.address().port, started: new Set() };
}
async function call({ port, started }, params) {
    const send = async (route, body) => {
        const init = body === undefined ? {} : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
        const { status, text } = await request(`http://127.0.0.1:${port}${route}`, init);
        if (status < 200 || status >= 300) {
            let message = text;
            try { message = JSON.parse(text).message || text; } catch { }
            throw new Error(`The source failed (HTTP ${status}): ${String(message).slice(0, 300)}`);
        }
        return text;
    };
    if (params.catConfig) return { result: await send('/config') };
    const api = String(params.catPawOpen || '');
    if (!/^\/spider\/[^?#]+$/.test(api)) throw new Error('Invalid CatPawOpen source');
    if (!started.has(api)) { await send(api + '/init', {}); started.add(api); }
    let route, body;
    if ('play' in params) { route = '/play'; body = { flag: params.flag || '', id: params.play }; }
    else if ('ids' in params) { route = '/detail'; body = { id: params.ids }; }
    else if ('wd' in params) { route = '/search'; body = { wd: params.wd, page: Number(params.pg || 1), quick: params.quick === 'true' }; }
    else if ('t' in params) { route = '/category'; body = { id: params.t, page: Number(params.pg || 1), filter: true, filters: {} }; }
    else { route = '/home'; body = {}; }
    const result = await send(api + route, body);
    // Sources address the bundle's own proxy by the device's network address, but the server is on loopback.
    return { result: result.replace(new RegExp(`http://\\d+\\.\\d+\\.\\d+\\.\\d+:${port}/`, 'g'), `http://127.0.0.1:${port}/`) };
}

const control = http.createServer(async (req, res) => {
    const reply = body => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (req.method !== 'POST' || req.url !== '/call' || req.headers['x-yingxia-token'] !== token) { res.writeHead(403); res.end(); return; }
    try {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        let instance = bundles.get(input.bundle);
        if (!instance) {
            // Bundles read the factory and NODE_PATH while they start, so starts take turns.
            instance = starting = starting.catch(() => { }).then(() => start(input));
            bundles.set(input.bundle, instance);
            instance.catch(() => bundles.delete(input.bundle));
        }
        reply(await call(await instance, input.params || {}));
    } catch (error) {
        log(error?.stack || String(error));
        reply({ error: String(error), errorCode: 'script_error' });
    }
});
control.listen(0, '127.0.0.1', () => {
    fs.writeFileSync(controlFile + '.tmp', JSON.stringify({ port: control.address().port, token }));
    fs.renameSync(controlFile + '.tmp', controlFile);
});
