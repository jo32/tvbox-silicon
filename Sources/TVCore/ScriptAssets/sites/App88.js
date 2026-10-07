// App88 family (摆烂, 长泽, 双星动漫): the author's app88.php bridge drives the upstream app API.
// ext: "https://.../app88.php?site=<name>" (or {"php"|"url"|"api": ..., "site"|"playname": ...}).
import { Bridge, BridgeReset, bridgeFilters } from './_bridge.js';
import { store, randomHex, sha256 } from './_lite.js';

const KEY = 'XyeDA1uF8x3WcIeE';
const IV = 'ohkb6oSM7yyZKZzo';
const ACCESS = ['FGAjpziyjdOV', '27f682b57aaf58c78e8c09cd22b34e324919470b25958322'];
const MEDIA = /\.(m3u8|mp4|ts|m4s|mpd|aac|key)$/i;

let bridge, profile, playname = '';
let state = '';

function endpoint(ext) {
    let address = String(ext || '').trim(), site = '';
    if (address.startsWith('{')) {
        const config = JSON.parse(address);
        address = String(config.php || config.url || config.api || '').trim();
        site = String(config.site || config.playname || '').trim();
    }
    const url = new URL(address);
    const query = url.searchParams.get('site');
    if (query) site = query; else if (site) address += (address.includes('?') ? '&' : '?') + 'site=' + encodeURIComponent(site);
    const kind = url.searchParams.get('bridge');
    if ((kind && kind.toLowerCase() !== 'app88') || !site) throw new Error('App88 bridge URL is invalid');
    return { php: address, site };
}

function uuid() {
    const h = randomHex(16);
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

function deviceProfile(site) {
    const saved = store('app88');
    const key = 'profile_' + sha256('com.himrsc.viz|' + site).slice(0, 32);
    let device = saved.json(key);
    if (!device || !/^[0-9a-f]{16}$/i.test(device.androidId || '')) {
        const now = Date.now();
        device = {
            schema: 1, uuid: uuid(), did: uuid(), androidId: randomHex(8), createdAt: now, updatedAt: now,
            name: 'Pixel 7', model: 'Pixel 7', device: 'panther', brand: 'google', manufacturer: 'Google', product: 'panther', hardware: 'panther',
            bootloader: 'unknown', display: 'TQ3A.230901.001', host: 'abfarm', tags: 'release-keys', type: 'user',
            finger: 'google/panther/panther:13/TQ3A.230901.001/10750268:user/release-keys', version: '13', sdkInt: 33, isPhysicalDevice: true,
            userAgent: 'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230901.001) AppleWebKit/537.36 Chrome/122.0 Mobile Safari/537.36'
        };
        saved.setJSON(key, device);
    }
    return device;
}

function takePlayname(object) { if (object && String(object.playname || '').trim()) playname = String(object.playname).trim(); }

function run(scene, params) {
    let current = state;
    for (let round = 0; round < 128; round++) {
        const prepare = { action: 'prepare', scene, params: params || {}, device_id: profile.did };
        if (current) prepare.state = current;
        const prepared = bridge.send(prepare);
        const next = String(prepared.state ?? current).trim();
        if (prepared.result && typeof prepared.result === 'object') { state = next; takePlayname(prepared); takePlayname(prepared.result); return prepared.result; }
        const ticket = String(prepared.ticket || '').trim();
        if (!prepared.request || !ticket) throw new Error('App88 bridge prepare response is invalid');
        let reply;
        try {
            const path = new URL(String(prepared.request.url).trim()).pathname;
            if (MEDIA.test(path)) throw new Error('App88 bridge target URL is invalid');
            reply = bridge.perform(prepared.request);
            if ('state' in prepared) state = next;
        } catch (error) {
            if (scene !== 'play') throw error;
            reply = { status: 599, headers: {}, body: '' };
        }
        const consumed = bridge.send({ action: 'consume', scene, ticket, status: reply.status, headers: reply.headers, body_b64: reply.body });
        const after = String(consumed.state ?? next).trim();
        if (consumed.result && typeof consumed.result === 'object') { state = after; takePlayname(consumed); takePlayname(consumed.result); return consumed.result; }
        if (consumed.terminal || !consumed.next) throw new Error('App88 bridge consume response is invalid');
        current = after;
    }
    throw new Error('App88 bridge request exceeded round limit');
}

function call(scene, params) {
    try { return run(scene, params); }
    catch (error) {
        if (!(error instanceof BridgeReset) || scene === 'init') throw error;
        state = '';
        run('init', { device: profile });
        return run(scene, params);
    }
}

const lineName = text => String(text || '').replace(/[#$]/g, ' ').trim() || '播放';

function vod(id, item) {
    return {
        vod_id: String(item.id || id), vod_name: String(item.name || ''), vod_pic: String(item.pic || ''), vod_remarks: String(item.remarks || ''),
        vod_year: String(item.year || ''), vod_area: String(item.area || ''), vod_actor: String(item.actor || ''), vod_director: String(item.director || ''),
        type_name: String(item.type || item.class || ''), vod_content: String(item.content || item.blurb || '')
    };
}

const videos = list => (Array.isArray(list) ? list : []).filter(v => v && String(v.id || '').trim() && String(v.name || '').trim()).map(v => vod('', v));

function page(pg, result) {
    const list = videos(result.list);
    const current = Number(result.page) > 0 ? Number(result.page) : pg;
    const count = Number(result.pagecount ?? result.pages) > 0 ? Number(result.pagecount ?? result.pages) : current;
    return { page: current, pagecount: count, limit: Number(result.limit) > 0 ? Number(result.limit) : 21, total: Math.max(Number(result.total) || list.length, list.length), list };
}

export default {
    init(ext) {
        const { php, site } = endpoint(ext);
        bridge = new Bridge({ php, site, key: KEY, iv: IV, access: ACCESS, label: 'app88_' + site });
        profile = deviceProfile(site);
        state = '';
        call('init', { device: profile });
        if (!state) throw new Error('App88 bridge state is missing');
    },
    home() {
        const result = call('home', {});
        const classes = (result.class || result.classes || []).filter(c => c && String(c.type_id ?? c.id ?? '').trim() && String(c.type_name ?? c.name ?? '').trim())
            .map(c => ({ type_id: String(c.type_id ?? c.id).trim(), type_name: String(c.type_name ?? c.name).trim() }));
        return { class: classes, list: videos(result.list), filters: result.filters || {} };
    },
    homeVod() { return { list: videos(call('home_video', {}).list) }; },
    category(tid, pg, filter, extend = {}) {
        const p = Math.min(100000, Math.max(1, parseInt(pg, 10) || 1));
        const ext = {};
        for (const [k, v] of Object.entries(extend || {})) if (k && v) ext[k] = v;
        return page(p, call('category', { tid: String(tid || ''), page: p, extend: ext }));
    },
    detail(id) {
        const result = call('detail', { id });
        if (!result.vod) return { list: [] };
        const item = vod(id, result.vod);
        const names = [], urls = [];
        for (const source of result.sources || []) {
            const episodes = [];
            (source.episodes || []).forEach((episode, index) => {
                const playId = String(episode.play_id ?? episode.id ?? '').trim();
                if (playId) episodes.push(lineName(String(episode.name || '').trim() || `第${index + 1}集`) + '$' + playId);
            });
            if (episodes.length) { names.push(lineName(String(source.name || '').trim() || `线路${names.length + 1}`)); urls.push(episodes.join('#')); }
        }
        item.vod_play_from = (playname ? names.map((n, i) => names.length > 1 ? `${playname}${i + 1}` : playname) : names).join('$$$');
        item.vod_play_url = urls.join('$$$');
        return { list: [item] };
    },
    search(wd, quick, pg) {
        const p = Math.min(100000, Math.max(1, parseInt(pg, 10) || 1));
        return page(p, call('search', { key: String(wd || ''), page: p }));
    },
    play(flag, id) {
        const result = call('play', { id: id || '' });
        const url = String(result.url || '').trim();
        if (!/^https?:\/\//.test(url)) throw new Error('App88 bridge play URL is invalid');
        const answer = { parse: 0, url };
        const header = {};
        for (const [k, v] of Object.entries(result.headers || {})) if (k && v) header[k] = String(v);
        if (Object.keys(header).length) answer.header = header;
        if (result.m3u8 || url.toLowerCase().includes('.m3u8')) answer.format = 'application/x-mpegURL';
        return answer;
    }
};
