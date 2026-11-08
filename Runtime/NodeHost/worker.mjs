// One CatPawOpen bundle, in a worker thread of its own (main.mjs starts it). The worker has its own V8 heap with a
// limit: a bundle that runs out of memory ends only this thread, where in the host's own isolate it aborted the app.
import http from 'node:http';
import { createRequire } from 'node:module';
import { parentPort, workerData } from 'node:worker_threads';
import { setProxy } from './agents.mjs';

const { bundle, configFile } = workerData;
let messagesPort = workerData.messagesPort;
setProxy(workerData.proxy);

function log(...values) { process.stderr.write(values.map(v => typeof v === 'string' ? v : JSON.stringify(v)).join(' ') + '\n'); }
process.env.NODE_ENV = 'development'; // Fastify then skips its per-request logger
Object.assign(console, { log, info: log, warn: log, error: log, debug: log });
// Some bundles' handlers answer a request twice; the CatVod apps keep serving, so this does too.
process.on('uncaughtException', error => log('CATPAW_UNCAUGHT', error?.stack || String(error)));
process.on('unhandledRejection', error => log('CATPAW_UNHANDLED', error?.stack || String(error)));
// Where bundles send their messages to the app: the host's `messages` server.
globalThis.catDartServerPort = () => messagesPort;

// A bundle's `start(config)` builds a Fastify app on the server `catServerFactory` makes, then lists its
// sources at GET /config and serves each at POST /spider/<key>/<type>/{init,home,category,detail,play,search}.
let server;
globalThis.catServerFactory = handler => {
    server = http.createServer(handler);
    const listen = server.listen.bind(server);
    server.listen = (...args) => listen(0, '127.0.0.1', args.find(arg => typeof arg === 'function'));
    return server;
};

parentPort.on('message', message => {
    if ('proxy' in message) setProxy(message.proxy);
    if (message.messagesPort) messagesPort = message.messagesPort;
    // iOS took the app's listening sockets back while it was suspended: listen on a new port.
    if (message.relisten) {
        const answer = reply => parentPort.postMessage({ relistened: message.relisten, ...reply });
        server.close();
        server.once('error', error => answer({ error: error.message }));
        server.listen(() => answer({ port: server.address().port }));
    }
});

try {
    const require = createRequire(bundle);
    // The bundle's settings sit beside it (index.js -> index.config.js); without them it starts with none.
    let config = {};
    if (configFile) {
        try {
            const module = require(configFile);
            config = module?.default ?? module ?? {};
        } catch (error) { log('CATPAW_CONFIG', error.message); }
    }
    const exports = require(bundle);
    if (typeof exports.start !== 'function') throw new Error('The script is not a CatPawOpen bundle');
    await exports.start(config);
    const deadline = Date.now() + 20_000;
    while (!server?.listening) {
        if (Date.now() > deadline) throw new Error('The CatPawOpen server did not start');
        await new Promise(resolve => setTimeout(resolve, 50));
    }
    parentPort.postMessage({ ready: true, port: server.address().port });
} catch (error) {
    parentPort.postMessage({ ready: false, error: error?.message || String(error) });
}
