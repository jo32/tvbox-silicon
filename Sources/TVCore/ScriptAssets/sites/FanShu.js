// 番薯动漫 (csp_FanShu): the author's fanshu.php bridge (fs_app_bridge_v2) signs the upstream app's
// requests: prepare -> perform -> consume, carrying a state token, until the bridge reports done.
// Search needs the site's arithmetic captcha, which this port does not solve; it then returns nothing.
// ext: "https://.../fanshu.php"
import { Bridge } from './_bridge.js';
import { store, randomHex, CookieJar } from './_lite.js';

const KEY = 'a7tgPzwpfCuL16+w';
const IV = 'gk529L41t6H2xw8Y';
const ACCESS = ['access', 'fs_app_bridge_v2'];

const saved = store('fanshu');
let bridge, state = '', sections = null;
let jar = new CookieJar();

const uuid = () => { const h = randomHex(16); return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${h.slice(16, 20)}-${h.slice(20)}`; };
const fromBase64 = text => {
    let value = String(text || '').trim();
    const comma = value.indexOf(',');
    if (comma >= 0 && value.slice(0, comma).toLowerCase().includes('base64')) value = value.slice(comma + 1);
    return value.replace(/-/g, '+').replace(/_/g, '/');
};

function perform(target) {
    const method = String(target.method || 'GET').toUpperCase();
    const headers = { ...(target.headers || {}) };
    const cookie = jar.toString();
    if (cookie) headers.Cookie = cookie;
    const options = { method: method === 'POST' ? 'POST' : 'GET', headers, buffer: 2, timeout: 30000 };
    if (method === 'POST') options.bodyBase64 = fromBase64(target.body_b64);
    try {
        const response = globalThis.req(String(target.url), options);
        jar.absorb(response.headers);
        saved.set('cookie', jar.toString());
        const replyHeaders = {};
        for (const name of ['Content-Type', 'Set-Cookie']) {
            const value = (response.headers || {})[name.toLowerCase()] ?? (response.headers || {})[name];
            if (value) replyHeaders[name] = String(Array.isArray(value) ? value[0] : value);
        }
        return { status: response.code || 0, headers: replyHeaders, body: typeof response.content === 'string' ? response.content : '' };
    } catch {
        return { status: 599, headers: {}, body: Buffer.from('{}', 'utf8').toString('base64') };
    }
}

function call(scene, params = {}) {
    const requestId = uuid();
    let current = state;
    for (let round = 0; round < 12; round++) {
        const prepared = bridge.send({ action: 'prepare', scene, request_id: requestId, client_time: Math.floor(Date.now() / 1000), state: current || '', params });
        const next = String(prepared.state ?? current);
        const ticket = String(prepared.ticket || '');
        if (!ticket) throw new Error('bridge ticket missing');
        const reply = perform(prepared);
        const consumed = bridge.send({ action: 'consume', scene, request_id: requestId, client_time: Math.floor(Date.now() / 1000), state: next, status: reply.status, headers: reply.headers, body: reply.body, ticket });
        current = String(consumed.state ?? next);
        state = current;
        saved.set('state', state);
        if (consumed.done) return consumed.data || {};
    }
    throw new Error('bridge flow exhausted');
}

function page(data, fallbackPage) {
    const list = (data.items || []).filter(v => v && v.id && v.name).map(v => ({ vod_id: String(v.id), vod_name: String(v.name), vod_pic: String(v.pic || ''), vod_remarks: String(v.remarks || '') }));
    return { page: Number(data.page) > 0 ? Number(data.page) : fallbackPage, pagecount: Math.max(1, Number(data.page_count) || 1), limit: Math.max(1, Number(data.limit) || 12), total: Math.max(list.length, Number(data.total) || 0), list, captcha: !!data.captcha_required };
}
const empty = p => ({ page: p, pagecount: 1, limit: 12, total: 0, list: [] });
const values = list => [{ n: '全部', v: '' }, ...[...new Set((list || []).map(v => String(v).trim()).filter(v => v && v !== '全部'))].map(v => ({ n: v, v }))];

function loadSections() {
    if (sections) return sections;
    try { sections = (call('home_sections').items || []).filter(Boolean); } catch { sections = []; }
    return sections;
}

export default {
    init(ext) {
        let address = String(ext || '').trim();
        if (address.startsWith('{')) { const c = JSON.parse(address); address = String(c.url || c.api || c.bridge || (c.endpoints || [])[0] || '').trim(); }
        if (!address.startsWith('http')) throw new Error('番薯桥接服务未配置');
        bridge = new Bridge({ php: address, site: '', key: KEY, iv: IV, access: ACCESS, label: 'fanshu' });
        jar = new CookieJar(saved.get('cookie'));
        state = saved.get('state') || '';
        sections = null;
    },
    home(filter) {
        const classes = [], filters = {};
        for (const section of loadSections()) {
            const id = String(section.id ?? 0);
            classes.push({ type_id: id, type_name: String(section.name || '') });
            if (!filter) continue;
            const groups = [];
            if ((section.classes || []).length) groups.push({ key: 'class', name: '分类', value: values(section.classes) });
            if ((section.years || []).length) groups.push({ key: 'year', name: '年份', value: values(section.years) });
            groups.push({ key: 'sort', name: '排序', value: [{ n: '全部', v: '' }, { n: '最新', v: 'latest' }, { n: '最热', v: 'hot' }] });
            filters[id] = groups;
        }
        return { class: classes, filters };
    },
    homeVod() {
        try {
            const first = loadSections()[0];
            const result = page(call('weekly_rankings', { type_id: first ? Number(first.id) || 0 : 0, limit: 15 }), 1);
            return result.captcha ? empty(1) : result;
        } catch { return empty(1); }
    },
    category(tid, pg, filter, extend = {}) {
        const p = Math.max(1, parseInt(pg, 10) || 1);
        const type = Math.max(0, parseInt(tid, 10) || 0);
        if (type <= 0) return empty(p);
        const result = page(call('category_videos', { type_id: type, page: p, class: (extend.class || '').trim(), year: (extend.year || '').trim(), sort: (extend.sort || '').trim() }), p);
        return result.captcha ? empty(p) : result;
    },
    detail(id) {
        const data = call('video_detail', { vod_id: String(id).trim() });
        if (!data.id && !data.name) return { list: [] };
        const froms = [], urls = [];
        for (const source of data.sources || []) {
            const episodes = (source && source.episodes || []).filter(Boolean).map((e, index) => {
                const token = 'v1.' + Buffer.from(JSON.stringify({ vod_id: String(data.id || id), source: String(source.key || ''), episode_index: e.index ?? index, episode_id: String(e.id || ''), vod_name: String(data.name || '') }), 'utf8').toString('base64url');
                const name = String(e.name || '').replace(/#/g, ' ').replace(/\$/g, '').trim() || '播放';
                return `${name}$${token}`;
            });
            if (episodes.length) { froms.push(String(source.name || source.key || `线路${froms.length + 1}`)); urls.push(episodes.join('#')); }
        }
        return { list: [{
            vod_id: String(data.id || id), vod_name: String(data.name || ''), vod_pic: String(data.pic || ''), vod_year: String(data.year || ''), vod_area: String(data.area || ''),
            type_name: String(data.type || ''), vod_remarks: String(data.remarks || ''), vod_actor: String(data.actor || ''), vod_director: String(data.director || ''),
            vod_content: String(data.content || ''), vod_play_from: froms.join('$$$'), vod_play_url: urls.join('$$$')
        }] };
    },
    search(wd, quick, pg) {
        const p = Math.max(1, parseInt(pg, 10) || 1);
        try {
            const result = page(call('search_videos', { keyword: String(wd || ''), page: p, page_size: 12 }), p);
            return result.captcha ? empty(p) : result;
        } catch { return empty(p); }
    },
    play(flag, id) {
        let token = String(id || '').trim();
        if (token.startsWith('v1.')) token = token.slice(3);
        let info;
        try { info = JSON.parse(Buffer.from(fromBase64(token), 'base64').toString('utf8')); } catch { info = null; }
        if (!info || !info.vod_id || !info.source) return { parse: 0, url: '', msg: '番薯播放标识无效' };
        let data = call('video_play', { vod_id: String(info.vod_id), source: String(info.source), episode_index: Number(info.episode_index) || 0, episode_id: String(info.episode_id || '') }) || {};
        for (const key of ['media', 'play', 'result', 'data']) if (data[key] && typeof data[key] === 'object') { data = data[key]; break; }
        const url = ['url', 'play_url', 'playUrl', 'media_url', 'src'].map(k => String(data[k] || '').trim()).find(Boolean) || '';
        if (!url) return { parse: 0, url: '', msg: '番薯播放地址解析失败' };
        const header = data.headers || data.header || data.request_headers || {};
        const result = { parse: Number(data.parse ?? data.jx ?? 0) || 0, url, header };
        if (data.m3u8 ?? url.toLowerCase().includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
