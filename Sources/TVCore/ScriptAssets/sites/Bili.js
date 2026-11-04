// 哔哩哔哩 (csp_Bili): Bilibili's public web APIs with WBI-signed requests. Three modes:
//   ext {"builtin": true, "cookie": "..."}: the app's built-in source: feeds, rankings, zones and PGC
//     catalogues; the cookie is the signed-in account's, supplied by the app and never stored here;
//   ext {"cookie": "..."}: PGC catalogues (番剧/国创/电影/电视剧/纪录片/综艺);
//   ext {"json": url}: keyword categories from a config file, listed through video search.
// Playback returns the CatVod `proxy?do=bili` address that the app resolves (DASH, else MP4).
import { md5, store } from './_lite.js';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const MIXIN = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52];
const PGC = [['pgc_1', '番剧', 1], ['pgc_4', '国创', 4], ['pgc_2', '电影', 2], ['pgc_5', '电视剧', 5], ['pgc_3', '纪录片', 3], ['pgc_7', '综艺', 7]];
const PGC_FILTER = [
    { key: 'order', name: '排序', value: [['播放数量', '2'], ['更新时间', '0'], ['最高评分', '4'], ['弹幕数量', '1'], ['追看人数', '3'], ['开播时间', '5'], ['上映时间', '6']].map(([n, v]) => ({ n, v })) },
    { key: 'season_status', name: '付费', value: [['全部', '-1'], ['免费', '1'], ['付费', '2,6'], ['大会员', '4,6']].map(([n, v]) => ({ n, v })) }
];
// Built-in mode: feeds first, then PGC, then the zones' three-day rankings (rid). The personalised
// feed (rcmd) is the home list, which the app shows as its recommendations.
const FEEDS = [['popular', '热门'], ['rank_0', '排行榜'], ['precious', '入站必刷']];
const ZONES = [[1, '动画'], [3, '音乐'], [129, '舞蹈'], [4, '游戏'], [36, '知识'], [188, '科技'], [234, '运动'], [223, '汽车'],
    [160, '生活'], [211, '美食'], [217, '动物圈'], [119, '鬼畜'], [155, '时尚'], [5, '娱乐'], [181, '影视']];
// Signed in: the account's own lists, after 热门; favourites folders follow as fav_<id>.
const MINE = [['my_dynamic', '关注动态'], ['my_later', '稍后再看'], ['my_history', '历史记录'], ['my_bangumi', '我的追番']];
const PROXY = 'http://127.0.0.1:9978/proxy';

const saved = store('bili');
let cookie = '';
let builtin = false;
let account = '';   // built-in mode: the app's signed-in account cookie
let config = null;  // keyword-category config in "json" mode
let mixinKey = '', mixinAt = 0;
let mid = 0;            // the signed-in account's id; -1 when the login has expired
const cursors = {};     // cursor-paged lists: list -> page -> where that page starts

const headers = () => ({ 'User-Agent': UA, Referer: 'https://www.bilibili.com/', Cookie: cookie });
const api = (url, extra = {}) => JSON.parse(globalThis.req(url, { headers: { ...headers(), ...extra } }).content || '{}');
const clean = text => String(text || '').replace(/<[^>]+>/g, '').replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
const pic = url => { const u = String(url || ''); return u.startsWith('//') ? 'https:' + u : u.replace(/^http:/, 'https:'); };
const two = n => String(n).padStart(2, '0');
// Seconds, or search's unpadded "m:s" text ("2:0"), as "2:00".
const clock = value => {
    const s = typeof value === 'string' && value.includes(':') ? value.split(':').reduce((sum, n) => sum * 60 + (Number(n) || 0), 0) : Number(value) || 0;
    if (!s) return '';
    const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60);
    return (h ? `${h}:${two(m)}` : String(m)) + ':' + two(s % 60);
};

// Built-in mode keeps only the anonymous buvid here, so signing out in the app really signs out.
function ensureCookie() {
    if (/buvid3=/.test(cookie)) return;
    const known = builtin ? saved.get('buvid') : '';
    if (known) { cookie = [account, known].filter(Boolean).join('; '); return; }
    try {
        const data = JSON.parse(globalThis.req('https://api.bilibili.com/x/frontend/finger/spi', { headers: { 'User-Agent': UA } }).content).data || {};
        if (!data.b_3) return;
        const buvid = [`buvid3=${data.b_3}`, data.b_4 ? `buvid4=${encodeURIComponent(data.b_4)}` : ''].filter(Boolean).join('; ');
        cookie = [cookie, buvid].filter(Boolean).join('; ');
        if (builtin) saved.set('buvid', buvid); else saved.set('cookie', cookie);
    } catch { /* anonymous requests still mostly work */ }
}

function dropBuvid() {
    cookie = cookie.replace(/;?\s*buvid[34]=[^;]*/g, '').replace(/^;\s*/, '');
    if (builtin) saved.set('buvid', ''); else saved.set('cookie', cookie);
}

function wbi(params) {
    if (!mixinKey || Date.now() - mixinAt > 3600000) {
        const nav = api('https://api.bilibili.com/x/web-interface/nav').data || {};
        const name = url => String(url || '').split('/').pop().split('.')[0];
        const raw = name((nav.wbi_img || {}).img_url) + name((nav.wbi_img || {}).sub_url);
        mixinKey = MIXIN.map(i => raw[i] || '').join('').slice(0, 32);
        mixinAt = Date.now();
    }
    const all = { ...params, wts: Math.floor(Date.now() / 1000) };
    const query = Object.keys(all).sort().map(k => `${encodeURIComponent(k)}=${encodeURIComponent(String(all[k]).replace(/[!'()*]/g, ''))}`).join('&');
    return query + '&w_rid=' + md5(query + mixinKey);
}

// Bilibili answers bursts of requests with a rate-limit code (-412 blocked, -352 risk control,
// -799 too frequent) and no results. QuickJS cannot sleep, so wait briefly in place and retry;
// risk control also gets a fresh buvid cookie.
const LIMITED = new Set([-412, -352, -799]);
function pause(ms) { const end = Date.now() + ms; while (Date.now() < end) { /* wait */ } }
function retrying(request) {
    let reply = {};
    for (let attempt = 0; attempt < 3; attempt++) {
        if (attempt) pause(1200 * attempt);
        try { reply = request(); } catch { reply = {}; }
        const code = Number(reply.code);
        if (code === 0 && (reply.data || reply.result)) return reply;
        if (code === -352) { dropBuvid(); ensureCookie(); }
        if (!LIMITED.has(code) && !isNaN(code) && reply.code !== undefined) return reply;
    }
    return reply;
}
const searchApi = params => retrying(() => api('https://api.bilibili.com/x/web-interface/wbi/search/type?' + wbi(params)));

const ugcItem = v => ({
    vod_id: v.bvid, vod_name: clean(v.title), vod_pic: pic(v.pic || v.cover),
    vod_remarks: [clock(v.duration), clean((v.owner || {}).name || v.author || '')].filter(Boolean).join(' · ')
});

function searchVideos(keyword, page, extra = {}) {
    ensureCookie();
    const data = searchApi({ search_type: 'video', keyword, page, ...extra }).data || {};
    return {
        list: (data.result || []).filter(v => v.bvid).map(v => builtin ? ugcItem(v) : ({ vod_id: v.bvid, vod_name: clean(v.title), vod_pic: pic(v.pic), vod_remarks: String(v.duration || '') })),
        pagecount: Number(data.numPages) || 1
    };
}

function searchSeasons(keyword) {
    ensureCookie();
    const list = [];
    for (const type of ['media_bangumi', 'media_ft']) {
        const data = searchApi({ search_type: type, keyword, page: 1, web_location: 1430654 }).data || {};
        for (const s of data.result || []) {
            if (!s.season_id) continue;
            const score = s.media_score && s.media_score.score ? ` ${s.media_score.score}分` : '';
            list.push({ vod_id: 'season_' + s.season_id, vod_name: clean(s.title), vod_pic: pic(s.cover), vod_remarks: String(s.index_show || '') + score });
        }
    }
    return list;
}

// Built-in feeds. Each answers { list, more } for one page.
function feed(tid, page) {
    ensureCookie();
    if (tid === 'rcmd') {
        const params = { fresh_type: 4, ps: 20, fresh_idx: page, fresh_idx_1h: page, brush: page, feed_version: 'V8', homepage_ver: 1, y_num: 4, web_location: 1430650 };
        const data = retrying(() => api('https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd?' + wbi(params))).data || {};
        return { list: (data.item || []).filter(v => v.bvid && (!v.goto || v.goto === 'av')).map(ugcItem), more: true };
    }
    if (tid === 'popular') {
        const data = retrying(() => api(`https://api.bilibili.com/x/web-interface/popular?ps=20&pn=${page}`)).data || {};
        return { list: (data.list || []).filter(v => v.bvid).map(ugcItem), more: !data.no_more };
    }
    if (tid === 'precious') {
        if (page > 1) return { list: [], more: false };
        const data = retrying(() => api('https://api.bilibili.com/x/web-interface/popular/precious?page_size=100&page=1')).data || {};
        return { list: (data.list || []).filter(v => v.bvid).map(ugcItem), more: false };
    }
    if (tid.startsWith('rank_')) {
        if (page > 1) return { list: [], more: false };
        // The ranking answers -352 (risk control) unless the request comes from the ranking page.
        const data = retrying(() => api('https://api.bilibili.com/x/web-interface/ranking/v2?' + wbi({ rid: tid.slice(5), type: 'all', web_location: 333.934 }),
            { Referer: 'https://www.bilibili.com/v/popular/rank/all' })).data || {};
        return { list: (data.list || []).filter(v => v.bvid).map(ugcItem), more: false };
    }
    return null;
}

const signedIn = () => builtin && /SESSDATA=/.test(account);
function me() {
    if (!mid) { const nav = api('https://api.bilibili.com/x/web-interface/nav').data || {}; mid = nav.isLogin ? Number(nav.mid) : -1; }
    return mid > 0 ? mid : 0;
}
const seasonItem = s => ({ vod_id: 'season_' + s.season_id, vod_name: clean(s.title), vod_pic: pic(s.cover), vod_remarks: String((s.new_ep && s.new_ep.index_show) || s.index_show || '') });

// The account's lists; null for any other id. Lists that page by cursor remember each next page's start.
function mine(tid, page) {
    if (!signedIn()) return tid.startsWith('my_') || tid.startsWith('fav_') ? { list: [], more: false } : null;
    const mark = (start) => { (cursors[tid] = cursors[tid] || {})[page + 1] = start; };
    const startOf = () => (page > 1 ? (cursors[tid] || {})[page] : null);
    if (tid === 'my_dynamic') {
        const offset = startOf();
        if (page > 1 && offset == null) return { list: [], more: false };
        const data = retrying(() => api(`https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all?type=video&page=${page}&offset=${offset || ''}&timezone_offset=-480`)).data || {};
        mark(data.offset);
        const list = (data.items || []).map(item => {
            const modules = item.modules || {};
            const video = ((modules.module_dynamic || {}).major || {}).archive;
            return video && video.bvid ? { vod_id: video.bvid, vod_name: clean(video.title), vod_pic: pic(video.cover),
                vod_remarks: [video.duration_text, clean((modules.module_author || {}).name)].filter(Boolean).join(' · ') } : null;
        }).filter(Boolean);
        return { list, more: !!data.has_more };
    }
    if (tid === 'my_later') {
        if (page > 1) return { list: [], more: false };
        const data = retrying(() => api('https://api.bilibili.com/x/v2/history/toview')).data || {};
        return { list: (data.list || []).filter(v => v.bvid).map(ugcItem), more: false };
    }
    if (tid === 'my_history') {
        const start = startOf();
        if (page > 1 && !start) return { list: [], more: false };
        const query = start ? `&max=${start.max}&view_at=${start.view_at}&business=${start.business || ''}` : '';
        const data = retrying(() => api('https://api.bilibili.com/x/web-interface/history/cursor?ps=20' + query)).data || {};
        const cursor = data.cursor || {};
        mark(cursor.max ? cursor : null);
        const list = (data.list || []).map(item => {
            const history = item.history || {};
            if (history.business === 'pgc' && item.kid) return { vod_id: 'season_' + item.kid, vod_name: clean(item.title), vod_pic: pic(item.cover), vod_remarks: clean(item.show_title || item.new_desc || '') };
            if (history.business === 'archive' && history.bvid) return { vod_id: history.bvid, vod_name: clean(item.title), vod_pic: pic(item.cover), vod_remarks: clean(item.author_name || '') };
            return null;
        }).filter(Boolean);
        return { list, more: (data.list || []).length > 0 && !!cursor.max };
    }
    if (tid === 'my_bangumi') {
        const id = me();
        if (!id) return { list: [], more: false };
        const data = retrying(() => api(`https://api.bilibili.com/x/space/bangumi/follow/list?type=1&follow_status=0&pn=${page}&ps=20&vmid=${id}`)).data || {};
        return { list: (data.list || []).map(seasonItem), more: page * 20 < Number(data.total || 0) };
    }
    if (tid.startsWith('fav_')) {
        const data = retrying(() => api(`https://api.bilibili.com/x/v3/fav/resource/list?media_id=${tid.slice(4)}&pn=${page}&ps=20&platform=web`)).data || {};
        const list = (data.medias || []).filter(v => v.bvid && (v.type === 2 || v.type == null)).map(v => ({ ...ugcItem({ ...v, pic: v.cover, owner: v.upper }) }));
        return { list, more: !!data.has_more };
    }
    return null;
}

// The most-liked comments, appended to a video's description.
function hotComments(aid) {
    try {
        const data = api(`https://api.bilibili.com/x/v2/reply/main?type=1&oid=${aid}&mode=3&ps=12`).data || {};
        const lines = (data.replies || []).slice(0, 12).map(r => `${clean((r.member || {}).uname)}：${clean((r.content || {}).message).replace(/\s+/g, ' ')}${r.like ? `  👍${r.like}` : ''}`);
        return lines.length ? '\n\n—— 热门评论 ——\n' + lines.join('\n') : '';
    } catch { return ''; }
}

const play = (aid, cid, ep = '') => `${aid}_${cid}${ep ? '_' + ep : ''}`;
const part = text => String(text || '').replace(/[#$]/g, ' ').trim();

export default {
    init(ext) {
        let options = {};
        try { options = typeof ext === 'string' ? JSON.parse(ext || '{}') : (ext || {}); } catch { options = {}; }
        builtin = options.builtin === true;
        account = builtin ? String(options.cookie || '') : '';
        cookie = builtin ? account : String(options.cookie || saved.get('cookie') || '');
        config = null;
        if (options.json) {
            try { config = JSON.parse(globalThis.req(options.json, { headers: { 'User-Agent': UA } }).content); } catch { config = { class: [] }; }
        }
    },
    home() {
        if (config) {
            const classes = (config.class || []).filter(c => c.type_id !== 'peizhi');
            return { class: classes, filters: config.filters || {} };
        }
        const filters = {};
        for (const [id] of PGC) filters[id] = PGC_FILTER;
        const classes = PGC.map(([type_id, type_name]) => ({ type_id, type_name }));
        if (!builtin) return { class: classes, filters };
        const feeds = FEEDS.map(([type_id, type_name]) => ({ type_id, type_name }));
        let own = [];
        if (signedIn() && me()) {
            const folders = (api(`https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=${me()}`).data || {}).list || [];
            own = [...MINE.map(([type_id, type_name]) => ({ type_id, type_name })), ...folders.map(f => ({ type_id: 'fav_' + f.id, type_name: '收藏·' + clean(f.title) }))];
        }
        return {
            class: [feeds[0], ...own, ...feeds.slice(1), ...classes, ...ZONES.map(([rid, type_name]) => ({ type_id: 'rank_' + rid, type_name }))],
            filters
        };
    },
    homeVod() {
        if (config) return { list: [] };
        if (builtin) return { list: feed('rcmd', 1).list };
        return this.category('pgc_1', '1', false, {});
    },
    category(tid, pg, filter, extend = {}) {
        const page = parseInt(pg, 10) || 1;
        const pgc = PGC.find(([id]) => id === tid);
        if (pgc) {
            const data = api(`https://api.bilibili.com/pgc/season/index/result?type=1&season_type=${pgc[2]}&order=${extend.order || 2}&season_status=${extend.season_status || -1}&page=${page}&pagesize=20`).data || {};
            const list = (data.list || []).map(s => ({ vod_id: 'season_' + s.season_id, vod_name: String(s.title || ''), vod_pic: pic(s.cover), vod_remarks: String(s.index_show || '') }));
            return { page, pagecount: data.has_next ? page + 1 : page, limit: 20, total: Number(data.total) || list.length, list };
        }
        const fed = builtin ? (feed(tid, page) || mine(tid, page)) : null;
        if (fed) {
            const more = fed.more && fed.list.length > 0;
            return { page, pagecount: more ? page + 1 : page, limit: fed.list.length, total: (page - 1) * 20 + fed.list.length + (more ? 1 : 0), list: fed.list };
        }
        const found = searchVideos(tid, page, extend.duration ? { duration: extend.duration } : {});
        return { page, pagecount: found.pagecount, limit: found.list.length, total: found.list.length * found.pagecount, list: found.list };
    },
    detail(id) {
        if (String(id).startsWith('season_')) {
            const result = api('https://api.bilibili.com/pgc/view/web/season?season_id=' + id.slice(7)).result || {};
            // Films often keep their only video in a section (正片) rather than in episodes.
            let source = result.episodes || [];
            if (!source.length) source = (result.section || []).flatMap(s => s.episodes || []);
            const episodes = source.map(e => `${part([e.title, e.long_title].filter(Boolean).join(' ')) || e.id}$${play(e.aid, e.cid, e.id)}`);
            return { list: [{
                vod_id: id, vod_name: String(result.title || ''), vod_pic: pic(result.cover), type_name: (result.styles || []).join(','),
                vod_year: String(result.publish && result.publish.pub_time || '').slice(0, 4), vod_area: (result.areas || []).map(a => a.name).join(','),
                vod_remarks: String(result.new_ep && result.new_ep.desc || ''), vod_actor: String(result.actors || '').replace(/\n/g, ' '),
                vod_content: String(result.evaluate || ''), vod_play_from: 'B站', vod_play_url: episodes.join('#')
            }] };
        }
        ensureCookie();
        const data = api('https://api.bilibili.com/x/web-interface/view?bvid=' + encodeURIComponent(id)).data || {};
        const groups = [['B站', (data.pages || []).map(p => `${part(p.part) || p.page}$${play(data.aid, p.cid)}`)]];
        // A video in a collection (合集) also offers the collection's other videos.
        const season = builtin ? data.ugc_season : null;
        if (season && season.sections) {
            const items = season.sections.flatMap(s => s.episodes || []).filter(e => e.aid && e.cid).slice(0, 500);
            if (items.length > 1) groups.push([part(season.title) || '合集', items.map(e => `${part(e.title) || e.aid}$${play(e.aid, e.cid)}`)]);
        }
        const stat = data.stat || {};
        return { list: [{
            vod_id: id, vod_name: String(data.title || ''), vod_pic: pic(data.pic), type_name: String(data.tname || ''),
            vod_year: data.pubdate ? String(new Date(data.pubdate * 1000).getFullYear()) : '',
            vod_remarks: builtin ? [clock(data.duration), stat.view ? `${stat.view} 播放` : ''].filter(Boolean).join(' · ') : `${(data.pages || []).length}P`,
            vod_director: String(data.owner && data.owner.name || ''), vod_content: String(data.desc || '') + (builtin && data.aid ? hotComments(data.aid) : ''),
            vod_play_from: groups.map(g => g[0]).join('$$$'), vod_play_url: groups.map(g => g[1].join('#')).join('$$$')
        }] };
    },
    search(wd, quick, pg) {
        if (config) return { list: searchVideos(wd, 1).list };
        if (!builtin) return { list: searchSeasons(wd) };
        const page = parseInt(pg, 10) || 1;
        const videos = searchVideos(wd, page);
        return { list: [...(page === 1 ? searchSeasons(wd) : []), ...videos.list], page, pagecount: videos.pagecount };
    },
    play(flag, id) {
        const [aid, cid, ep] = String(id).split('_');
        return { parse: 0, url: `${PROXY}?do=bili&aid=${aid}&cid=${cid}${ep ? '&ep=' + ep : ''}&qn=80`, header: { Referer: 'https://www.bilibili.com/', 'User-Agent': UA } };
    }
};
