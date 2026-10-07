// 哔哩哔哩 (csp_Bili): Bilibili's public web APIs with WBI-signed search. Two modes:
//   ext {"cookie": "..."}: PGC catalogues (番剧/国创/电影/电视剧/纪录片/综艺);
//   ext {"json": url}: keyword categories from a config file, listed through video search.
// Playback returns the CatVod `proxy?do=bili` address that the app resolves to a progressive MP4.
import { md5, store } from './_lite.js';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const MIXIN = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52];
const PGC = [['pgc_1', '番剧', 1], ['pgc_4', '国创', 4], ['pgc_2', '电影', 2], ['pgc_5', '电视剧', 5], ['pgc_3', '纪录片', 3], ['pgc_7', '综艺', 7]];
const PGC_FILTER = [
    { key: 'order', name: '排序', value: [['播放数量', '2'], ['更新时间', '0'], ['最高评分', '4'], ['弹幕数量', '1'], ['追看人数', '3'], ['开播时间', '5'], ['上映时间', '6']].map(([n, v]) => ({ n, v })) },
    { key: 'season_status', name: '付费', value: [['全部', '-1'], ['免费', '1'], ['付费', '2,6'], ['大会员', '4,6']].map(([n, v]) => ({ n, v })) }
];
const PROXY = 'http://127.0.0.1:9978/proxy';

const saved = store('bili');
let cookie = '';
let config = null;  // keyword-category config in "json" mode
let mixinKey = '', mixinAt = 0;

const headers = () => ({ 'User-Agent': UA, Referer: 'https://www.bilibili.com/', Cookie: cookie });
const api = (url) => JSON.parse(globalThis.req(url, { headers: headers() }).content || '{}');
const clean = text => String(text || '').replace(/<[^>]+>/g, '').replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
const pic = url => { const u = String(url || ''); return u.startsWith('//') ? 'https:' + u : u; };

function ensureCookie() {
    if (/buvid3=/.test(cookie)) return;
    try {
        const data = JSON.parse(globalThis.req('https://api.bilibili.com/x/frontend/finger/spi', { headers: { 'User-Agent': UA } }).content).data || {};
        if (data.b_3) cookie = [cookie, `buvid3=${data.b_3}`, data.b_4 ? `buvid4=${encodeURIComponent(data.b_4)}` : ''].filter(Boolean).join('; ');
        saved.set('cookie', cookie);
    } catch { /* anonymous requests still mostly work */ }
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

function searchVideos(keyword, page, extra = {}) {
    ensureCookie();
    const data = api('https://api.bilibili.com/x/web-interface/wbi/search/type?' + wbi({ search_type: 'video', keyword, page, ...extra })).data || {};
    return {
        list: (data.result || []).filter(v => v.bvid).map(v => ({ vod_id: v.bvid, vod_name: clean(v.title), vod_pic: pic(v.pic), vod_remarks: String(v.duration || '') })),
        pagecount: Number(data.numPages) || 1
    };
}

function searchSeasons(keyword) {
    ensureCookie();
    const list = [];
    for (const type of ['media_bangumi', 'media_ft']) {
        const data = api('https://api.bilibili.com/x/web-interface/wbi/search/type?' + wbi({ search_type: type, keyword, page: 1, web_location: 1430654 })).data || {};
        for (const s of data.result || []) {
            if (!s.season_id) continue;
            const score = s.media_score && s.media_score.score ? ` ${s.media_score.score}分` : '';
            list.push({ vod_id: 'season_' + s.season_id, vod_name: clean(s.title), vod_pic: pic(s.cover), vod_remarks: String(s.index_show || '') + score });
        }
    }
    return list;
}

const play = (aid, cid, ep = '') => `${aid}_${cid}${ep ? '_' + ep : ''}`;

export default {
    init(ext) {
        let options = {};
        try { options = typeof ext === 'string' ? JSON.parse(ext || '{}') : (ext || {}); } catch { options = {}; }
        cookie = String(options.cookie || saved.get('cookie') || '');
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
        return { class: PGC.map(([type_id, type_name]) => ({ type_id, type_name })), filters };
    },
    homeVod() {
        if (config) return { list: [] };
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
        const found = searchVideos(tid, page, extend.duration ? { duration: extend.duration } : {});
        return { page, pagecount: found.pagecount, limit: found.list.length, total: found.list.length * found.pagecount, list: found.list };
    },
    detail(id) {
        if (String(id).startsWith('season_')) {
            const result = api('https://api.bilibili.com/pgc/view/web/season?season_id=' + id.slice(7)).result || {};
            const episodes = (result.episodes || []).map(e => `${[e.title, e.long_title].filter(Boolean).join(' ').replace(/[#$]/g, ' ') || e.id}$${play(e.aid, e.cid, e.id)}`);
            return { list: [{
                vod_id: id, vod_name: String(result.title || ''), vod_pic: pic(result.cover), type_name: (result.styles || []).join(','),
                vod_year: String(result.publish && result.publish.pub_time || '').slice(0, 4), vod_area: (result.areas || []).map(a => a.name).join(','),
                vod_remarks: String(result.new_ep && result.new_ep.desc || ''), vod_actor: String(result.actors || '').replace(/\n/g, ' '),
                vod_content: String(result.evaluate || ''), vod_play_from: 'B站', vod_play_url: episodes.join('#')
            }] };
        }
        ensureCookie();
        const data = api('https://api.bilibili.com/x/web-interface/view?bvid=' + encodeURIComponent(id)).data || {};
        const pages = (data.pages || []).map(p => `${String(p.part || p.page).replace(/[#$]/g, ' ')}$${play(data.aid, p.cid)}`);
        return { list: [{
            vod_id: id, vod_name: String(data.title || ''), vod_pic: pic(data.pic), type_name: String(data.tname || ''),
            vod_remarks: `${(data.pages || []).length}P`, vod_director: String(data.owner && data.owner.name || ''), vod_content: String(data.desc || ''),
            vod_play_from: 'B站', vod_play_url: pages.join('#')
        }] };
    },
    search(wd) {
        return { list: config ? searchVideos(wd, 1).list : searchSeasons(wd) };
    },
    play(flag, id) {
        const [aid, cid] = String(id).split('_');
        return { parse: 0, url: `${PROXY}?do=bili&aid=${aid}&cid=${cid}&qn=80`, header: { Referer: 'https://www.bilibili.com/', 'User-Agent': UA } };
    }
};
