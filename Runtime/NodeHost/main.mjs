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

// Node 18 (nodejs-mobile) defaults to a new connection for every request; desktop Node 19+ keeps them
// alive. Bundles using axios's default agents can make several requests to one site in quick succession
// (address probes, searches with fallback paths, challenge cookies). Reuse those connections on iOS too:
// repeatedly opening TLS connections made the 9280.kstore.vip sites reset the handshake before answering.
// Bundles' own agents and their TLS verification settings remain theirs.
http.globalAgent.keepAlive = true;
https.globalAgent.keepAlive = true;

const [controlFile, relistenFile] = process.argv.slice(2);
const token = crypto.randomBytes(16).toString('hex');
function log(...values) { process.stderr.write(values.map(v => typeof v === 'string' ? v : JSON.stringify(v)).join(' ') + '\n'); }
process.env.NODE_ENV = 'development'; // Fastify then skips its per-request logger
Object.assign(console, { log, info: log, warn: log, error: log, debug: log });
// Some bundles' handlers answer a request twice; the CatVod apps keep serving, so this does too.
process.on('uncaughtException', error => log('CATPAW_UNCAUGHT', error?.stack || String(error)));
process.on('unhandledRejection', error => log('CATPAW_UNHANDLED', error?.stack || String(error)));
// Where bundles send their messages to the app (`messages`).
globalThis.catDartServerPort = () => messages?.address()?.port || 0;

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

// Bundles ask the app for things by POSTing {action, opt} to http://127.0.0.1:<catDartServerPort()>/msg, as the CatVod
// Open apps take them. The host's `messages` server answers that address (`answerMessage`). The one request kept is a
// page to open: a config center entry asks for its page that way ("openInternalWebview") and may say nothing else
// about it (#315). Keep in step with host.mjs.
// The 豆儿 and Lmentor bundles ask for their own page at the device's network address, as a phone would scan it
// (http://192.168.1.5:<port>/website, #385): it counts once it is on the bundle's server (`loopbackPage`).
const pageWatchers = new Set(); // the detail calls under way, each told the pages asked for
async function answerMessage(req, res) {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let message = {};
    try { message = JSON.parse(Buffer.concat(chunks).toString('utf8')) || {}; } catch { }
    const page = String(message.opt?.url || '');
    if (message.action === 'getPlayInfo') {
        catPlaying.asked = Date.now();
        const { title, episodeName, flag } = catPlaying;
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ title, episodeName, flag }));
        return;
    }
    if (message.action === 'danmuPush' && loopbackPage(page)) catPushed = { url: page.replace('//localhost:', '//127.0.0.1:'), at: Date.now() };
    if (['openInternalWebview', 'openWeb'].includes(message.action) && /^http:\/\/(127\.0\.0\.1|localhost|\d+\.\d+\.\d+\.\d+):\d+(\/|$)/.test(page)) {
        for (const watch of pageWatchers) watch(page);
    }
    // Anything else gets nothing back, as when no one answered: the bundle carries on without it.
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('null');
}
// The page on loopback, as the app opens it, or undefined when it is served anywhere else.
const loopbackPage = page => page && /^http:\/\/(127\.0\.0\.1|localhost):\d+(\/|$)/.test(page) ? page : undefined;
const isMessage = req => req.method === 'POST' && req.url === '/msg';

// CatPawOpen bundles find danmaku for what plays, as the CatVod Open apps take it (#506): a moment after a play the
// 9280.kstore.vip bundle asks the app what plays ("getPlayInfo": {title, episodeName, flag}), matches that in its own
// danmu_api and sends the comments' address back ("danmuPush": http://127.0.0.1:<port>/danmu/auto?name=…&episode=…).
// The host names each play from the detail answers it passed on; the app asks for the address with `catDanmaku` and
// fetches the comments itself. A bundle that never asks gets no answer it didn't get before. Keep in step with host.mjs.
const catTitles = new Map(); // play id -> {title, episodeName, flag}, from the latest detail answers
let catPlaying = { title: '', episodeName: '', flag: '', at: 0, asked: 0 }, catPushed = { url: '', at: 0 };
function rememberTitles(text) {
    let list;
    try { list = JSON.parse(text)?.list; } catch { return; }
    for (const video of Array.isArray(list) ? list : []) {
        const title = String(video?.vod_name ?? '').trim();
        if (!title) continue;
        const flags = String(video.vod_play_from ?? '').split('$$$');
        String(video.vod_play_url ?? '').split('$$$').forEach((line, index) => {
            for (const item of line.split('#')) {
                const cut = item.indexOf('$');
                const episodeName = cut < 0 ? '' : item.slice(0, cut).trim(), id = cut < 0 ? item : item.slice(cut + 1);
                if (!id.trim()) continue;
                catTitles.delete(id);
                catTitles.set(id, { title, episodeName, flag: flags[index] || '' });
            }
        });
    }
    while (catTitles.size > 3000) catTitles.delete(catTitles.keys().next().value);
}
function startedPlaying(flag, id) {
    const known = catTitles.get(id);
    catPlaying = { title: known?.title || '', episodeName: known?.episodeName || '', flag: flag || known?.flag || '', at: Date.now(), asked: 0 };
}
// The comments' address for an episode: the one the bundle sent for this play, or else its /danmu/auto for the name
// the app asks with (a bundle without it answers 404). `pending` while the bundle may still send one: it asks what
// plays 800 ms after the play and sends the address straight after the answer.
function danmakuAddress(port, params) {
    const now = Date.now(), name = String(params.name || ''), episode = String(params.episode || '');
    const current = catPlaying.title === name && catPlaying.episodeName === episode;
    const pushed = current && catPushed.at >= catPlaying.at && catPushed.url.startsWith(`http://127.0.0.1:${port}/`) ? catPushed.url : '';
    const pending = current && !pushed && now - catPlaying.at < 3000 && !(catPlaying.asked && now - catPlaying.asked > 500);
    const query = new URLSearchParams({ name });
    if (episode) query.set('episode', episode);
    return { result: JSON.stringify({ url: pushed || `http://127.0.0.1:${port}/danmu/auto?${query}`, pushed: !!pushed, pending }) };
}
// Messages go to a server of the host's own: a bundle that finds its own port behind catDartServerPort() skips the call
// as a call to itself (BRIDGE_SELF_CALL in the 豆儿 and Lmentor bundles), so pages they ask for never arrived (#385).
const messages = http.createServer((req, res) => {
    if (isMessage(req)) return answerMessage(req, res);
    res.writeHead(404); res.end();
});
messages.on('error', error => log('CATPAW_MESSAGES', error?.stack || String(error)));
messages.listen(0, '127.0.0.1');
// A detail answer for which the bundle asked to open a page: the page's address joins the video's synopsis, where the
// app finds a config center (CatPawOpen.configCenter). Some bundles answer such an entry with an empty list.
function withPage(text, page) {
    let answer;
    try { answer = JSON.parse(text); } catch { return text; }
    if (!answer || typeof answer !== 'object' || Array.isArray(answer)) return text;
    const list = Array.isArray(answer.list) ? answer.list : [];
    const video = list[0] && typeof list[0] === 'object' ? list[0] : {};
    if (!`${video.vod_content ?? ''}\n${video.vod_remarks ?? ''}`.includes(page)) {
        video.vod_content = [video.vod_content, page].filter(Boolean).join('\n');
    }
    answer.list = [video, ...list.slice(1)];
    return JSON.stringify(answer);
}
// The detail calls collect what pages the bundle asks to open while it answers. The 豆儿 and Lmentor bundles answer a
// config entry with an empty video first and ask for its page a moment later (#385), so an answer with nothing to play
// waits briefly for that; a video's details come back at once.
async function watchingPages(route, send) {
    if (!route.endsWith('/detail')) return { text: await send() };
    let page, arrived;
    const watch = address => { page = address; arrived?.(); };
    pageWatchers.add(watch);
    try {
        const text = await send();
        if (!page && !playable(text)) await new Promise(resolve => { arrived = resolve; setTimeout(resolve, 300); });
        return { text, page };
    } finally { pageWatchers.delete(watch); }
}
function playable(text) {
    try { return (JSON.parse(text)?.list ?? []).some(video => video?.vod_play_url); } catch { return true; }
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
// show. Bundles of the wexfnw family take a drive's cookie at PUT /website/api/credential/<drive>/cookie as {value}, and
// the Xunlei sign-in (its device and tokens) as their whole Xunlei config. The catpaw.douer.me bundle (豆儿) takes the
// cookie at PUT /website/<drive>/cookie as {cookie} (#651). Each sign-in passes on once per change in the app, so the
// bundle's own refreshes of it stay. Keep in step with host.mjs.
const sharedDrives = { quark: 'quarkCookie', uc: 'ucCookie', baidu: 'baiduCookie' };
const cookieRoutes = [
    { route: drive => `/website/api/credential/${drive}/cookie`, body: value => ({ value }), thunder: true },
    { route: drive => `/website/${drive}/cookie`, body: value => ({ cookie: value }) },
];
function sharedSignIns(accounts, layout) {
    const shares = Object.entries(sharedDrives)
        .map(([drive, key]) => ({ drive, route: layout.route(drive), value: String(accounts[key] || '').trim(), body: layout.body }));
    // A bundle from before Xunlei sign-ins lacks this address; the other drives still pass.
    if (layout.thunder) shares.push({ drive: 'thunder', route: '/website/api/thunder/config', value: accounts.xunlei ? JSON.stringify(accounts.xunlei) : '', body: value => ({ value }), optional: true });
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
    // The bundle's layout is the first that takes a cookie; until then each is tried in turn.
    for (const layout of instance.cookieLayout ? [instance.cookieLayout] : cookieRoutes) {
        let missing = false;
        for (const { drive, route, value, body, optional } of sharedSignIns(accounts, layout)) {
            if (!value || given[drive] === digest(value)) continue;
            const { status, text } = await request(`http://127.0.0.1:${instance.port}${route}`,
                { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body(value)) });
            // The config center answers {code: 0}. Its refusal ({code: -1, message}) leaves the other drives to pass; any
            // other answer is a bundle without a config center at this address.
            let answer;
            try { answer = JSON.parse(text); } catch { }
            if (!(status >= 200 && status < 300 && answer?.code === 0)) {
                if (optional || (status !== 404 && answer?.code !== undefined)) continue;
                missing = true; break;
            }
            instance.cookieLayout = layout;
            given[drive] = digest(value); changed = true; log('CATPAW_ACCOUNT', drive);
        }
        if (!missing) break;
        if (instance.cookieLayout || layout === cookieRoutes.at(-1)) { instance.takesAccounts = false; break; }
    }
    if (changed) fs.writeFileSync(givenFile, JSON.stringify(given));
}
// Bundles keep their sites' connections open in their own keep-alive agents (the 9280.kstore.vip bundle's shared axios,
// used by its 秒播 sites), and reuse one the far end has since dropped: a server's idle timeout, or a proxy or NAT
// between. That request fails at once with "socket hang up" and the bundle answers HTTP 500. One more try opens a
// fresh connection. A slow hang-up is a server that drops every request, so it isn't asked twice. Keep in step with
// host.mjs.
async function sendFresh(send, route, body) {
    const started = Date.now();
    try { return await send(route, body); } catch (error) {
        if (error.status !== 500 || !/socket hang up|ECONNRESET|EPIPE/.test(error.message) || Date.now() - started > 2500) throw error;
        log('CATPAW_RETRY', route, error.message);
        return send(route, body);
    }
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
            throw Object.assign(new Error(`The source failed (HTTP ${status}): ${String(message).slice(0, 300)}`), { status });
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
    if (params.catDanmaku) return danmakuAddress(instance.port, params);
    const api = String(params.catPawOpen || '');
    if (!/^\/spider\/[^?#]+$/.test(api)) throw new Error('Invalid CatPawOpen source');
    // A site without an init route is ready as it is: the xiaosage.361123.xyz bundle's drive sites (玩偶, 花卷, 原盘…)
    // answer its POST with HTTP 404 "站点或接口不存在" and serve everything else (#446). Keep in step with host.mjs.
    if (!instance.started.has(api)) {
        await send(api + '/init', {}).catch(error => { if (error.status !== 404) throw error; });
        instance.started.add(api);
    }
    let route, body;
    if ('play' in params) { route = '/play'; body = { flag: params.flag || '', id: params.play }; startedPlaying(body.flag, body.id); }
    else if ('ids' in params) { route = '/detail'; body = { id: params.ids }; }
    else if ('wd' in params) { route = '/search'; body = { wd: params.wd, page: Number(params.pg || 1), quick: params.quick === 'true' }; }
    else if ('t' in params) { route = '/category'; body = { id: params.t, page: Number(params.pg || 1), filter: true, filters: params.filters ? JSON.parse(params.filters) : {} }; }
    else { route = '/home'; body = {}; }
    // A search that finds nothing answers HTTP 404 in some bundles: the 9280.kstore.vip sites (木偶, 虎斑, 蜡笔…) pass on
    // their site's 404 for a search without matches, and a source without search has no route. Sources whose search
    // returns nothing at all (its 少儿 and 体育 sites) answer 200 with an empty body. None of these is a failure.
    const { text, page } = await watchingPages(route, () => sendFresh(send, api + route, body)
        .then(text => route === '/search' && !text.trim() ? '{"list":[]}' : text)
        .catch(error => { if (route === '/search' && error.status === 404) return '{"list":[]}'; throw error; }));
    if (route === '/detail') rememberTitles(text);
    // Sources address the bundle's own proxy by the device's network address, or by a port from before a relisten,
    // but the server is on loopback.
    const ports = instance.ports.join('|');
    const local = address => address.replace(new RegExp(`http://\\d+\\.\\d+\\.\\d+\\.\\d+:(?:${ports})/`, 'g'), `http://127.0.0.1:${instance.port}/`);
    const result = local(text), shown = loopbackPage(page && local(page));
    return { result: shown ? withPage(result, shown) : result };
}

// A bundle's media proxy address from before a relisten, at the port that bundle listens on now: a stream that was
// playing when iOS suspended the app asks again there (#485). The address as it is when no bundle had its port.
async function relocate(address) {
    const url = new URL(address);
    for (const pending of bundles.values()) {
        const instance = await pending.catch(() => null);
        if (!instance?.ports.includes(Number(url.port))) continue;
        url.port = String(instance.port);
        return url.toString();
    }
    return address;
}

const control = http.createServer(async (req, res) => {
    const reply = body => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (req.method !== 'POST' || req.url !== '/call' || req.headers['x-yingxia-token'] !== token) { res.writeHead(403); res.end(); return; }
    try {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (input.relocate) { reply({ result: await relocate(String(input.relocate)) }); return; }
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
        await listen(messages);
        await listen(control);
        announce();
        log('CATPAW_RELISTEN', control.address().port);
    })().finally(() => { relistening = null; });
    return relistening;
}
fs.watch(relistenFile, () => relisten().catch(error => log('CATPAW_RELISTEN', error?.stack || String(error))));
control.on('error', error => log('CATPAW_CONTROL', error?.stack || String(error)));
control.listen(0, '127.0.0.1', announce);
