// Client for the plugin author's server-driven "bridge" (NiuLai, App88, AppUn, ...). Messages are
// AES-CBC JSON in a {"moyufucking": base64} envelope. The server returns an HTTP request to perform
// plus a ticket; the client performs it and "consumes" the reply until the server returns a result.
import { aesEncrypt, aesDecrypt, randomHex, store, http, sha256 } from './_lite.js';

const toBase64 = text => Buffer.from(String(text), 'utf8').toString('base64');
const fromBase64 = data => Buffer.from(String(data || ''), 'base64').toString('utf8');
export const b64url = text => Buffer.from(String(text), 'utf8').toString('base64url');
export const unb64url = data => Buffer.from(String(data || '').replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');

function sleep(ms) {
    const until = Date.now() + Math.max(0, Math.min(Number(ms) || 0, 2000));
    while (Date.now() < until) { /* scripts run synchronously */ }
}

function waitOf(answer, ...names) {
    for (const name of names) if (answer[name] != null) return Number(answer[name]) || 0;
    return 0;
}

export class BridgeReset extends Error {}

/**
 * options: { php, site, key, iv, access: [name, secret], label, stateKey, extra }
 * `extra` is merged into every prepare message (e.g. playname for AppUn).
 */
export class Bridge {
    constructor(options) {
        this.o = options;
        this.saved = store(options.label || 'bridge');
        let identity = this.saved.json('identity');
        if (!identity) {
            identity = { device: randomHex(8), hardware: randomHex(6).match(/../g).join(':') };
            this.saved.setJSON('identity', identity);
        }
        this.device = identity.device;
        this.hardware = identity.hardware;
        this.stateKey = 'state_' + sha256([options.php, options.site, this.device, this.hardware].join('\n'));
        this.state = this.saved.json(this.stateKey);
        this.ready = false;
    }

    send(message) {
        const [name, secret] = this.o.access;
        const plain = JSON.stringify({ [name]: secret, ...message });
        const body = JSON.stringify({ moyufucking: aesEncrypt(plain, this.o.key, this.o.iv) });
        const response = http(this.o.php, { method: 'POST', body, redirect: false, timeout: 30000, allowError: true, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
        let envelope;
        try { envelope = JSON.parse(response.content); } catch { throw new Error(`${this.o.label} bridge HTTP ${response.code}: ${String(response.content).slice(0, 200)}`); }
        if (!envelope || typeof envelope.moyufucking !== 'string') throw new Error(`${this.o.label} bridge HTTP ${response.code}: ${String(response.content).slice(0, 200)}`);
        const answer = JSON.parse(aesDecrypt(envelope.moyufucking, this.o.key, this.o.iv));
        if (response.code >= 400 && !answer.ok) throw new Error(`${this.o.label} bridge HTTP ${response.code}: ${answer.error || JSON.stringify(answer).slice(0, 200)}`);
        if (answer.ok) {
            if (!answer.data) throw new Error(this.o.label + ' bridge data missing');
            return answer.data;
        }
        const data = answer.data || {};
        if ('state' in data) { this.keep(data.state); throw new Error(answer.error || this.o.label + ' bridge failed'); }
        if (answer.reset) { this.keep(null); this.ready = false; throw new BridgeReset(answer.error || 'state expired'); }
        throw new Error(answer.error || this.o.label + ' bridge failed');
    }

    keep(state) {
        this.state = state == null ? null : state;
        this.saved.setJSON(this.stateKey, this.state);
    }

    perform(request) {
        const method = String(request.method || 'GET').trim().toUpperCase();
        if (!['GET', 'POST', 'HEAD'].includes(method)) throw new Error('bridge target method is invalid');
        const headers = {};
        for (const [name, value] of Object.entries(request.headers && !Array.isArray(request.headers) ? request.headers : {})) if (name && value) headers[name] = String(value);
        const options = { method, headers, buffer: 2, timeout: 30000 };
        if (method === 'POST') options.bodyBase64 = String(request.body_b64 || '');
        const response = globalThis.req(String(request.url).trim(), options);
        const answerHeaders = {};
        for (const [name, value] of Object.entries(response.headers || {})) answerHeaders[name.toLowerCase()] = String(value);
        return { status: response.code || 0, headers: answerHeaders, body: typeof response.content === 'string' ? response.content : '' };
    }

    /** Run one scene to completion and return its result object. */
    call(scene, params = {}, retry = true) {
        try {
            for (let round = 0; round < 48; round++) {
                const prepared = this.send({ action: 'prepare', site: this.o.site, scene, params, state: this.state, device_id: this.device, hardware_id: this.hardware, ...(this.o.extra || {}) });
                if (prepared.meta) this.o.onMeta?.(prepared.meta);
                if ('state' in prepared) this.state = prepared.state;
                if (!prepared.request) throw new Error(this.o.label + ' bridge prepare request missing');
                sleep(waitOf(prepared, 'wait_ms', 'waitMs', 'delay_ms'));
                const reply = this.perform(prepared.request);
                const consumed = this.send({ action: 'consume', site: this.o.site, scene, ticket: prepared.ticket ?? null, status: reply.status, body: reply.body, ...(this.o.extra || {}) });
                if (consumed.meta) this.o.onMeta?.(consumed.meta);
                if ('state' in consumed) this.state = consumed.state;
                if (!consumed.next) {
                    if ('state' in consumed) this.keep(consumed.state);
                    return consumed.result && typeof consumed.result === 'object' && !Array.isArray(consumed.result) ? consumed.result : {};
                }
                sleep(waitOf(consumed, 'delay_ms'));
            }
            throw new Error(this.o.label + ' bridge exceeded round limit');
        } catch (error) {
            if (!(error instanceof BridgeReset) || !retry) throw error;
            this.ensure();
            return this.call(scene, params, false);
        }
    }

    /** The `init` scene, once per session unless state was restored. */
    ensure() {
        if (this.ready) return;
        if (this.state == null) this.call('init', { sdk: 28 }, false);
        this.ready = true;
    }
}

/** Probe the first 4 KiB of a media address like the spiders do before trusting it. */
export function mediaLooksValid(url, headers) {
    let response;
    try { response = globalThis.req(url, { headers: { ...headers, Range: 'bytes=0-4095', 'Accept-Encoding': 'identity', 'Cache-Control': 'no-cache' }, timeout: 15000 }); }
    catch { return false; }
    if (response.code !== 200 && response.code !== 206) return false;
    const type = String((response.headers || {})['content-type'] || '').toLowerCase();
    const head = String(response.content || '').slice(0, 4096).trim().toLowerCase();
    const address = String(url).toLowerCase();
    if (type.includes('text/html') || type.includes('application/json') || type.includes('application/xml')
        || head.startsWith('<html') || head.startsWith('<!doctype') || head.startsWith('<error') || head.startsWith('{"code"') || head.includes('nosuchkey')) return false;
    if (address.includes('.m3u8') || type.includes('mpegurl')) return head.startsWith('#extm3u');
    if (address.includes('.mp4') || type.startsWith('video/')) return true;
    return head.length > 0;
}

/** CatVod filters from the bridge's {tid: [{key, name, values: [{n, v}]}]}. */
export function bridgeFilters(filters) {
    const out = {};
    for (const [tid, groups] of Object.entries(filters || {})) {
        const list = (Array.isArray(groups) ? groups : []).map(g => ({ key: String(g.key || '').trim(), name: String(g.name || g.key || '').trim(), value: (g.values || []).filter(v => v && v.n).map(v => ({ n: String(v.n), v: String(v.v ?? '') })) }))
            .filter(g => g.key && g.value.length);
        if (list.length) out[tid] = list;
    }
    return out;
}

export const bridgeVideos = list => (Array.isArray(list) ? list : []).filter(v => v && v.id && v.name)
    .map(v => ({ vod_id: String(v.id), vod_name: String(v.name), vod_pic: String(v.pic || ''), vod_remarks: String(v.remarks || '') }));

export function bridgePage(page, result) {
    const current = Math.max(1, Number(result.page) || page);
    const limit = Math.max(1, Number(result.limit) || 20);
    const total = Math.max(0, Number(result.total) || 0);
    const pagecount = Math.max(current, Number(result.pagecount) || (total === 0 ? current : Math.ceil(total / limit)));
    return { page: current, pagecount, limit, total, list: bridgeVideos(result.list) };
}
