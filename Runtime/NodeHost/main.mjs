// CatPawOpen (猫源) bundles on iPhone and iPad. EmbeddedNodeHost starts this once in the app's nodejs-mobile
// and calls it over loopback: POST /call {bundle, api, profile, cloudAccounts, proxy, params} with the token it writes beside
// its port. It mirrors the CatPawOpen mode of Runtime/ScriptHost/host.mjs (the Mac's sandboxed host); keep them in step.
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const [controlFile, relistenFile] = process.argv.slice(2);
const token = crypto.randomBytes(16).toString('hex');
function log(...values) { process.stderr.write(values.map(v => typeof v === 'string' ? v : JSON.stringify(v)).join(' ') + '\n'); }
process.env.NODE_ENV = 'development'; // Fastify then skips its per-request logger
Object.assign(console, { log, info: log, warn: log, error: log, debug: log });
// Some bundles' handlers answer a request twice; the CatVod apps keep serving, so this does too.
process.on('uncaughtException', error => log('CATPAW_UNCAUGHT', error?.stack || String(error)));
process.on('unhandledRejection', error => log('CATPAW_UNHANDLED', error?.stack || String(error)));
globalThis.catDartServerPort = () => 0;

// The app reaches the internet through the system's HTTP proxy when one is set (Settings > Wi-Fi > Configure
// Proxy), but Node's sockets don't, so every agent's connections tunnel through it with CONNECT. A VPN-style
// proxy needs nothing: iOS routes Node's sockets through it like the app's own.
let proxy = null; // {host, port, exceptions} from EmbeddedNodeHost, updated on every call
function direct(host) {
    host = String(host || '').replace(/^\[|\]$/g, '').toLowerCase();
    if (!proxy || host === 'localhost' || host.endsWith('.local') || /^(127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|::1$|fe80:)/.test(host)) return true;
    return proxy.exceptions.some(rule => {
        rule = rule.toLowerCase();
        return rule.startsWith('*.') ? host.endsWith(rule.slice(1)) : host === rule;
    });
}
function tunnel(options, secure, callback) {
    const host = options.host || options.hostname || 'localhost';
    const port = options.port || (secure ? 443 : 80);
    const socket = net.connect(proxy.port, proxy.host);
    const fail = error => { socket.destroy(); callback(error); };
    socket.once('error', fail);
    socket.once('connect', () => socket.write(`CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n\r\n`));
    let head = Buffer.alloc(0);
    socket.on('data', function answer(chunk) {
        head = Buffer.concat([head, chunk]);
        const end = head.indexOf('\r\n\r\n');
        if (end < 0) return;
        socket.off('data', answer);
        socket.off('error', fail);
        const status = Number(head.toString('latin1', 0, end).split(' ')[1]);
        if (status !== 200) return fail(new Error(`The proxy ${proxy.host}:${proxy.port} refused ${host}:${port} (HTTP ${status})`));
        if (end + 4 < head.length) socket.unshift(head.subarray(end + 4));
        callback(null, secure ? tls.connect({ ...options, socket, servername: options.servername ?? (net.isIP(host) ? undefined : host) }) : socket);
    });
}
for (const [Agent, secure] of [[http.Agent, false], [https.Agent, true]]) {
    const connect = Agent.prototype.createConnection;
    Agent.prototype.createConnection = function (options, callback) {
        if (direct(options.host || options.hostname)) return connect.call(this, options, callback);
        tunnel(options, secure, callback);
    };
}
// Kept-alive sockets are pooled by name, so a changed proxy doesn't reuse sockets made without it.
// https.Agent's getName builds on this one.
const getName = http.Agent.prototype.getName;
http.Agent.prototype.getName = function (options = {}) {
    const name = getName.call(this, options);
    return direct(options.host || options.hostname) ? name : `${name}:via:${proxy.host}:${proxy.port}`;
};

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
const bundles = new Map(); // bundle file -> Promise<{server, port, ports, started}>
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
    const port = server.address().port;
    return { server, port, ports: [port], started: new Set() };
}
// The app's cloud-drive sign-ins, for bundles that keep their own and sign in through a config center the app can't
// show. Bundles of the wexfnw family take a drive's cookie at PUT /website/api/credential/<drive>/cookie, and the
// Xunlei sign-in (its device and tokens) as their whole Xunlei config. Each sign-in passes on once per change in the
// app, so the bundle's own refreshes of it stay. Keep in step with host.mjs.
const sharedDrives = { quark: 'quarkCookie', uc: 'ucCookie', baidu: 'baiduCookie' };
function sharedSignIns(accounts) {
    const shares = Object.entries(sharedDrives)
        .map(([drive, key]) => ({ drive, route: `/website/api/credential/${drive}/cookie`, value: String(accounts[key] || '').trim() }));
    // A bundle from before Xunlei sign-ins lacks this address; the other drives still pass.
    shares.push({ drive: 'thunder', route: '/website/api/thunder/config', value: accounts.xunlei ? JSON.stringify(accounts.xunlei) : '', optional: true });
    return shares;
}
async function shareAccounts(instance, accountsFile, profile) {
    if (!accountsFile || instance.takesAccounts === false) return;
    let stamp;
    try { stamp = fs.statSync(accountsFile).mtimeMs; } catch { return; }
    if (stamp === instance.accountsStamp) return;
    instance.accountsStamp = stamp;
    const accounts = JSON.parse(fs.readFileSync(accountsFile, 'utf8'));
    const givenFile = `${profile}/yingxia-accounts.json`;
    let given = {};
    try { given = JSON.parse(fs.readFileSync(givenFile, 'utf8')); } catch { }
    const digest = text => crypto.createHash('sha256').update(text).digest('hex');
    let changed = false;
    for (const { drive, route, value, optional } of sharedSignIns(accounts)) {
        if (!value || given[drive] === digest(value)) continue;
        const { status, text } = await request(`http://127.0.0.1:${instance.port}${route}`,
            { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ value }) });
        // The config center answers {code: 0}; anything else is a bundle without one.
        let saved = false;
        try { saved = status >= 200 && status < 300 && JSON.parse(text).code === 0; } catch { }
        if (!saved) { if (optional) continue; instance.takesAccounts = false; break; }
        given[drive] = digest(value); changed = true; log('CATPAW_ACCOUNT', drive);
    }
    if (changed) fs.writeFileSync(givenFile, JSON.stringify(given));
}
async function call(instance, params) {
    const send = async (route, body) => {
        const init = body === undefined ? {} : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
        const ask = () => request(`http://127.0.0.1:${instance.port}${route}`, init);
        // A refused connection means iOS took the bundle's socket back while the app was suspended.
        const { status, text } = await ask().catch(async error => {
            if (error.code !== 'ECONNREFUSED') throw error;
            await relisten();
            return ask();
        });
        if (status < 200 || status >= 300) {
            let message = text;
            try { message = JSON.parse(text).message || text; } catch { }
            throw new Error(`The source failed (HTTP ${status}): ${String(message).slice(0, 300)}`);
        }
        return text;
    };
    if (params.catConfig) return { result: await send('/config') };
    // A sign-in the bundle's config center runs with its own QR code (UC's TV token), for accounts the app has no
    // sign-in page for. Keep in step with host.mjs.
    if (params.catLogin) {
        if (!['start', 'poll', 'cancel'].includes(params.catLogin)) throw new Error('Invalid CatPawOpen sign-in');
        return { result: await send(`/website/api/login/${params.catLogin}`, { provider: params.provider || '', taskId: params.taskId || '' }) };
    }
    const api = String(params.catPawOpen || '');
    if (!/^\/spider\/[^?#]+$/.test(api)) throw new Error('Invalid CatPawOpen source');
    if (!instance.started.has(api)) { await send(api + '/init', {}); instance.started.add(api); }
    let route, body;
    if ('play' in params) { route = '/play'; body = { flag: params.flag || '', id: params.play }; }
    else if ('ids' in params) { route = '/detail'; body = { id: params.ids }; }
    else if ('wd' in params) { route = '/search'; body = { wd: params.wd, page: Number(params.pg || 1), quick: params.quick === 'true' }; }
    else if ('t' in params) { route = '/category'; body = { id: params.t, page: Number(params.pg || 1), filter: true, filters: {} }; }
    else { route = '/home'; body = {}; }
    const result = await send(api + route, body);
    // Sources address the bundle's own proxy by the device's network address, or by a port from before a relisten,
    // but the server is on loopback.
    const ports = instance.ports.join('|');
    return { result: result.replace(new RegExp(`http://\\d+\\.\\d+\\.\\d+\\.\\d+:(?:${ports})/`, 'g'), `http://127.0.0.1:${instance.port}/`) };
}

const control = http.createServer(async (req, res) => {
    const reply = body => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (req.method !== 'POST' || req.url !== '/call' || req.headers['x-yingxia-token'] !== token) { res.writeHead(403); res.end(); return; }
    try {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        proxy = input.proxy?.host ? { host: input.proxy.host, port: Number(input.proxy.port), exceptions: input.proxy.exceptions || [] } : null;
        let instance = bundles.get(input.bundle);
        if (!instance) {
            // Bundles read the factory and NODE_PATH while they start, so starts take turns.
            instance = starting = starting.catch(() => { }).then(() => start(input));
            bundles.set(input.bundle, instance);
            instance.catch(() => bundles.delete(input.bundle));
        }
        instance = await instance;
        await shareAccounts(instance, input.cloudAccounts, input.profile).catch(error => log('CATPAW_ACCOUNT', error?.stack || String(error)));
        reply(await call(instance, input.params || {}));
    } catch (error) {
        log(error?.stack || String(error));
        reply({ error: String(error), errorCode: 'script_error' });
    }
});
function announce() {
    fs.writeFileSync(controlFile + '.tmp', JSON.stringify({ port: control.address().port, token }));
    fs.renameSync(controlFile + '.tmp', controlFile);
}

// iOS takes back the listening sockets of a suspended app, and they then refuse connections. EmbeddedNodeHost
// appends a line to `relistenFile` when the control port refuses it; every server then listens on a new port.
let relistening = null;
function relisten() {
    relistening ??= (async () => {
        const listen = server => new Promise(resolve => { server.close(); server.listen(0, '127.0.0.1', resolve); });
        for (const pending of bundles.values()) {
            const instance = await pending.catch(() => null);
            if (!instance) continue;
            await listen(instance.server);
            instance.port = instance.server.address().port;
            instance.ports.push(instance.port);
        }
        await listen(control);
        announce();
        log('CATPAW_RELISTEN', control.address().port);
    })().finally(() => { relistening = null; });
    return relistening;
}
fs.watch(relistenFile, () => relisten().catch(error => log('CATPAW_RELISTEN', error?.stack || String(error))));
control.on('error', error => log('CATPAW_CONTROL', error?.stack || String(error)));
control.listen(0, '127.0.0.1', announce);
