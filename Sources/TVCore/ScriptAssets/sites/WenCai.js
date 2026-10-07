// 文才影视 (csp_WenCai): the mw-movie anonymous API; each request is signed sha1(md5(query + key + t)).
// ext: comma-separated site addresses; the first that answers a HEAD request is used.
import { md5, sha1 } from './_lite.js';

const KEY = 'cb808529bae6b6be45ecfab29a4889bc';
const PLAY_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36';
const AREAS = ['中国大陆', '中国香港', '中国台湾', '美国', '日本', '韩国', '泰国', '印度', '其他'];

let site = 'https://www.hkybqufgh.com';

function normalize(address) {
    const colon = address.indexOf(':');
    const scheme = colon > 0 ? address.slice(0, colon) : 'https';
    const rest = (colon > 0 ? address.slice(Math.min(colon + 3, address.length)) : address).replace(/\/+$/, '');
    return scheme + '://' + rest;
}

/** GET an API path; `signed` is the query string the server signs (keys in the server's order). */
function api(path, signed) {
    const t = String(Date.now());
    const headers = { sign: sha1(md5(`${signed}${signed ? '&' : ''}key=${KEY}&t=${t}`)), T: t, Deviceid: 'Deviceid', 'User-Agent': 'okhttp/4.9.3' };
    return JSON.parse(globalThis.req(`${site}/api/mw-movie/anonymous/${path}`, { headers }).content || '{}');
}

const video = v => ({ vod_id: String(v.vodId ?? ''), vod_name: String(v.vodName || ''), vod_pic: String(v.vodPic || ''), vod_remarks: String(v.vodVersion ?? v.vodRemarks ?? '') });

export default {
    init(ext) {
        site = normalize('https://www.hkybqufgh.com');
        for (const entry of String(ext || '').split(',')) {
            const candidate = entry.trim();
            if (!candidate.startsWith('http')) continue;
            const address = normalize(candidate);
            try {
                const code = globalThis.req(address, { method: 'HEAD', timeout: 8000 }).code;
                if (code >= 200 && code < 400) { site = address; return; }
            } catch { /* try the next one */ }
        }
    },
    home(filter) {
        const classes = [['1', '电影'], ['2', '电视剧'], ['4', '动漫'], ['3', '综艺']].map(([type_id, type_name]) => ({ type_id, type_name }));
        const years = [{ n: '全部', v: '' }];
        for (let y = 2025; y >= 2010; y--) years.push({ n: String(y), v: String(y) });
        years.push(...['2009~2000', '90年代', '80年代'].map(v => ({ n: v, v })));
        const groups = [{ key: 'area', name: '地区', value: [{ n: '全部', v: '' }, ...AREAS.map(v => ({ n: v, v }))] }, { key: 'year', name: '年份', value: years }];
        const filters = {};
        for (const c of classes) filters[c.type_id] = groups;
        let list = [];
        try { list = (api('home/hotSearch', '').data || []).map(video); } catch { /* optional */ }
        return { class: classes, list, filters };
    },
    category(tid, pg, filter, extend = {}) {
        const area = extend.area || '', year = extend.year || '';
        const data = api(`video/list?type1=${tid}&pageNum=${pg}&area=${area}&year=${year}`, `area=${area}&pageNum=${pg}&type1=${tid}&year=${year}`).data || {};
        return { list: (data.list || []).map(video) };
    },
    detail(id) {
        const data = api(`video/detail?id=${id}`, `id=${id}`).data || {};
        const item = {
            vod_id: String(data.vodId ?? id), vod_name: String(data.vodName || ''), vod_pic: String(data.vodPic || ''), vod_year: String(data.vodYear || ''),
            vod_area: String(data.vodArea || ''), vod_actor: String(data.vodActor || ''), vod_director: String(data.vodDirector || ''),
            vod_content: String(data.vodContent || ''), type_name: String(data.typeName || '')
        };
        const episodes = data.episodeList || [];
        if (episodes.length) {
            item.vod_play_from = '文才';
            item.vod_play_url = episodes.map((e, i) => `${e.name || `第${i + 1}集`}$${id}@${e.nid ?? 0}`).join('#');
        }
        return { list: [item] };
    },
    search(wd, quick, pg = '1') {
        const data = api(`video/searchByWord?keyword=${encodeURIComponent(wd)}&pageNum=${pg}&pageSize=20`, `keyword=${wd}&pageNum=${pg}&pageSize=20`).data || {};
        return { list: ((data.result || {}).list || []).filter(v => v.vodClass !== '伦理').map(video) };
    },
    play(flag, id) {
        const [vid, nid = ''] = String(id).split('@');
        const data = api(`v2/video/episode/url?id=${vid}&nid=${nid}`, `id=${vid}&nid=${nid}`).data || {};
        const url = String(((data.list || [])[0] || {}).url || '');
        return { parse: 0, url, header: { 'User-Agent': PLAY_UA, Origin: site, Referer: site } };
    }
};
