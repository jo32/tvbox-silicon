// 视界 (fty csp_App99Guard): an encrypted MacCMS app API ("app/bn") described by the (encrypted) ext:
// {"host", "appkey", "versionName", "name", "package", "buildNumber", "buildSignature", "version", "token"}.
// Bodies both ways are base64(iv16 + AES-256-CBC(json)) keyed by the device uuid without dashes; replies are
// also zlib-compressed. Headers carry sign = sha256("<body>:<timestamp>:<nonce>:<token>:<appkey>").
// Episode ids keep the JAR's "<url>@<player code>@<title>@<episode>" form.
import { ftyConfig } from './_fty.js';
import { sha256, randomHex, store, httpJSON } from './_lite.js';

const saved = store('app99');
let config = {}, uuid = '', key = '', players = {}, parsers = [], categories = [], blocked = [];
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.6299.95 Safari/537.36';

function newUuid() { const h = randomHex(16); return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${h.slice(16, 20)}-${h.slice(20)}`; }
function encrypt(text) {
    const iv = randomHex(16);
    const ct = globalThis.nativeCrypto({ op: 'aes', encrypt: true, mode: 'CBC', keyText: key, ivHex: iv, dataText: text, output: 'hex' }).hex;
    return Buffer.from(iv + ct, 'hex').toString('base64');
}
function decrypt(text) {
    const hex = Buffer.from(String(text || '').trim(), 'base64').toString('hex');
    if (hex.length < 64) return '';
    const request = { op: 'aes', encrypt: false, mode: 'CBC', keyText: key, ivHex: hex.slice(0, 32), dataHex: hex.slice(32) };
    const plain = globalThis.nativeCrypto({ ...request, output: 'base64' }).data;
    try { return globalThis.nativeCrypto({ op: 'inflate', data: plain }).text; } catch { return Buffer.from(plain, 'base64').toString('utf8'); }
}
function call(path, params) {
    const nonce = Buffer.from(randomHex(16), 'hex').toString('base64');
    const timestamp = String(Date.now());
    const token = String(config.token || '');
    const body = encrypt(JSON.stringify({ ...params, nonce, token, timestamp }));
    const headers = {
        Accept: 'application/json', 'Content-Type': 'application/json', client_type: 'android', 'User-Agent': UA, uuid, timestamp, nonce,
        sign: sha256(`${body}:${timestamp}:${nonce}:${token}:${config.appkey || ''}`), appkey: String(config.appkey || ''),
        version: String(config.version || '0b4328287a5d953e'), api_version: 'v1'
    };
    const response = globalThis.req(config.host + path, { method: 'POST', headers, body, timeout: 20000 });
    const text = decrypt(response.content);
    return text ? JSON.parse(text) : {};
}
const card = v => ({ vod_id: String(v.id), vod_name: String(v.name || ''), vod_pic: String(v.pic || ''), vod_remarks: String(v.remarks || '') });
const list = data => (data.data || []).filter(v => v && v.id != null).map(card);

export default {
    init(ext) {
        config = ftyConfig(ext);
        config.host = String(config.host || '').replace(/\/+$/, '');
        if (!config.host) throw new Error('App99: ext has no host');
        uuid = String(config.uuid || saved.get('uuid') || '');
        if (!uuid) { uuid = newUuid(); saved.set('uuid', uuid); }
        key = uuid.replace(/-/g, '');
        const init = call('/app/systemInit', { s: String(config.buildSignature || ''), apiVersion: 'v2', v: String(config.versionName || ''), pl: '1', n: String(config.name || '') });
        players = init.player || {};
        parsers = init.parser_api || [];
        categories = ((init.categorys || {}).data || []).filter(c => c && Number(c.pid || 0) === 0);
        try {
            call(config.LoginPath || '/app/userInfo', { package: String(config.package || ''), appName: String(config.name || ''), appkey: String(config.appkey || ''),
                buildSignature: String(config.buildSignature || ''), buildNumber: String(config.buildNumber || ''), uuid, version: String(config.versionName || '') });
        } catch {}
    },
    home() {
        return { class: categories.map(c => ({ type_id: String(c.id), type_name: String(c.name) })), list: list(call('/vod/search', { isCategory: 1, limit: 12, orderBy: 'time', pid: '0', page: '1', kw: '' })) };
    },
    category(tid, pg) {
        const page = String(parseInt(pg, 10) || 1);
        const data = call('/vod/search', { isCategory: 1, limit: 21, orderBy: 'time', pid: String(tid), page, kw: '' });
        return { page: Number(page), pagecount: Number(data.page_count) || 1, limit: 21, total: Number(data.total_count) || 0, list: list(data) };
    },
    detail(id) {
        const v = call('/vod/detail', { v: '2.0.0', eps: '1', id: String(id), pl: 1 }).data;
        if (!v) return { list: [] };
        const skip = new Set((v.un_player || []).map(String));
        const froms = String(v.play_from || '').split('$$$'), urls = String(v.play_url || '').split('$$$');
        const lines = [];
        froms.forEach((code, i) => {
            if (!code || skip.has(code) || !urls[i]) return;
            const episodes = urls[i].split('#').map(e => { const [title, url] = e.split('$'); return url ? `${title}$${url}@${code}@${v.name}@${title}` : null; }).filter(Boolean);
            if (episodes.length) lines.push([String((players[code] || {}).name || code), episodes.join('#')]);
        });
        return { list: [{
            vod_id: String(v.id), vod_name: String(v.name || ''), vod_pic: String(v.pic || ''), vod_remarks: String(v.remarks || ''), vod_year: String(v.year || ''),
            vod_area: String(v.area || ''), type_name: String(v.class || ''), vod_actor: String(v.actor || ''), vod_director: String(v.director || ''),
            vod_content: String(v.content || v.blurb || '').replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&nbsp;/g, ' ').trim(),
            vod_play_from: lines.map(l => l[0]).join('$$$'), vod_play_url: lines.map(l => l[1]).join('$$$')
        }] };
    },
    search(wd, quick, pg) {
        return { list: list(call('/vod/search', { limit: 21, orderBy: 'vod_hits_month', page: parseInt(pg, 10) || 1, sort: 'desc', kw: String(wd) })) };
    },
    play(flag, id) {
        const parts = String(id).split('@');
        const code = parts.length >= 4 ? parts[parts.length - 3] : '';
        const url = parts.length >= 4 ? parts.slice(0, parts.length - 3).join('@') : String(id);
        const player = players[code] || {};
        let header = {};
        try { header = JSON.parse(player.headers || '{}') || {}; } catch {}
        const media = /\.(m3u8|mp4|flv)(\?|$)/i.test(url);
        if (Number(player.isParse) === 1 && !media) {
            const parser = parsers.find(p => String(p.id) === String(player.parseUrl));
            if (parser && String(parser.api_type) === 'json') {
                try {
                    const data = httpJSON(parser.api_url + encodeURIComponent(url), { timeout: (Number(parser.api_time_out) || 10) * 1000 });
                    const found = String(data[parser.idx_play_url || 'url'] || '');
                    if (/^https?:\/\//.test(found)) return { parse: 0, url: found, header };
                } catch {}
            }
            return { parse: 1, url, header };
        }
        return { parse: media || !/^https?:\/\//.test(url) ? 0 : 1, url, header };
    }
};
