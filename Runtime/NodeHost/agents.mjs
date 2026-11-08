// Networking for the host (main.mjs) and each bundle's worker (worker.mjs). Every thread has its own copy of Node's
// http modules, so each one runs this to set them up.
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';

// Node 18 (nodejs-mobile) defaults to a new connection for every request; desktop Node 19+ keeps them
// alive. Bundles using axios's default agents can make several requests to one site in quick succession
// (address probes, searches with fallback paths, challenge cookies). Reuse those connections on iOS too:
// repeatedly opening TLS connections made the 9280.kstore.vip sites reset the handshake before answering.
// Bundles' own agents and their TLS verification settings remain theirs.
http.globalAgent.keepAlive = true;
https.globalAgent.keepAlive = true;

// The app reaches the internet through the system's HTTP proxy when one is set (Settings > Wi-Fi > Configure
// Proxy), but Node's sockets don't, so every agent's connections tunnel through it with CONNECT. A VPN-style
// proxy needs nothing: iOS routes Node's sockets through it like the app's own.
let proxy = null; // {host, port, exceptions} from EmbeddedNodeHost, updated on every call
export function setProxy(value) { proxy = value?.host ? { host: value.host, port: Number(value.port), exceptions: value.exceptions || [] } : null; }
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
export function request(url, { method = 'GET', headers = {}, body, timeout = 60_000 } = {}, redirects = 5) {
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
