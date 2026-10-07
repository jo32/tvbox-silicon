// 听风知秋 (csp_zhiqiu): an app API whose request bodies/forms are produced by the author's zhiqiu.php
// (do=zhiqiu1: API base + UA, zhiqiu2: signed JSON body, zhiqiu3: signed form fields).
// ext: "http://.../zhiqiu.php"
import { http, aesEncrypt, aesDecrypt } from './_lite.js';

const KEY = 'ZhiQiu@Transit!!';
const IV = 'zhiqiu9999999999';
const ACCESS = ['v7m', 'MoYu@ZhiQiu2026!'];
const SEP = '|||';
const MEDIA = /https?:\/\/[^\s]+\.(m3u8|mp4|flv|avi|mkv|rmvb|wmv|mpg|mpeg|mov|ts)/;
const NUMBERS = ['', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十', '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十'];
const QUALITY = [['4K', '4K高码'], ['2K', '2K'], ['直连', '直连(有广可投屏)'], ['超清', '超清'], ['极速', '极速'], ['蓝光', '蓝光'], ['高清', '高清'], ['标清', '标清'], ['1080', '1080P'], ['720', '720P']];

let php = '', base = '', ua = 'okhttp/4.12.0';

const isMedia = url => !/url=http|\.js|\.css|\.html/.test(url) && MEDIA.test(url);

/** One bridge call; zhiqiu.php answers with the object itself (no ok/data envelope). */
function service(action, payload) {
    const [name, secret] = ACCESS;
    const plain = JSON.stringify({ [name]: secret, ...payload });
    try {
        const response = http(`${php}?do=${action}`, { method: 'POST', body: JSON.stringify({ moyufucking: aesEncrypt(plain, KEY, IV) }), headers: { 'Content-Type': 'application/json; charset=utf-8' } });
        const envelope = JSON.parse(response.content || '{}');
        if (!envelope.moyufucking) return null;
        const answer = JSON.parse(aesDecrypt(envelope.moyufucking, KEY, IV));
        return answer.error ? null : answer;
    } catch { return null; }
}

/** POST JSON whose body the bridge signs (zhiqiu2). */
function postJSON(path, params) {
    const answer = service('zhiqiu2', { params });
    if (!answer) return {};
    const response = globalThis.req(base + path, { method: 'POST', body: String(answer.body || '{}'), headers: { 'User-Agent': ua, 'Content-Type': 'application/json; charset=utf-8' } });
    try { return JSON.parse(response.content); } catch { return {}; }
}

/** POST a form whose fields the bridge signs (zhiqiu3). */
function postForm(path, params) {
    const strings = {};
    for (const [k, v] of Object.entries(params)) strings[k] = String(v);
    const answer = service('zhiqiu3', { params: strings });
    if (!answer || !answer.params) return {};
    const body = Object.entries(answer.params).map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(String(v))).join('&');
    const response = globalThis.req(base + path, { method: 'POST', body, headers: { 'User-Agent': ua, 'Content-Type': 'application/x-www-form-urlencoded' } });
    try { return JSON.parse(response.content); } catch { return {}; }
}

const video = v => ({ vod_id: String(v.id ?? ''), vod_name: String(v.name || ''), vod_pic: String(v.videoPic || ''), vod_remarks: String(v.remarks || '') });
const result = (url, header, parse = 0) => { const r = { parse, url }; if (header) r.header = header; return r; };

function filterGroup(key, name, values) {
    if (!values) return null;
    return { key, name, value: [{ n: '全部', v: '' }, ...String(values).split(',').map(v => v.trim()).filter(Boolean).map(v => ({ n: v, v }))] };
}

function viaParse(parseUrl, code) {
    try {
        const answer = JSON.parse(globalThis.req(parseUrl + code, { headers: { 'User-Agent': ua } }).content);
        const url = String(answer.url || '');
        if (!url.startsWith('http')) return null;
        const agent = String(answer.ua || answer['User-Agent'] || '');
        return result(url, agent ? { 'User-Agent': agent } : null);
    } catch { return null; }
}

export default {
    init(ext) {
        php = String(ext || '').trim().replace(/\/$/, '');
        const config = service('zhiqiu1', {});
        if (config) {
            if (Array.isArray(config.urls) && config.urls.length) base = String(config.urls[0]).replace(/\/$/, '');
            if (config.ua) ua = String(config.ua);
        }
    },
    home(filter) {
        const data = postJSON('/api/v1/video/classifies', {}).data || [];
        const classes = [], filters = {};
        for (const item of data) {
            const id = String(item.id);
            classes.push({ type_id: id, type_name: String(item.name) });
            if (!filter || !item.extend) continue;
            const groups = [filterGroup('class', '类型', item.extend.class), filterGroup('area', '地区', item.extend.area), filterGroup('year', '年份', item.extend.year), filterGroup('lang', '语言', item.extend.lang)].filter(Boolean);
            if (groups.length) filters[id] = groups;
        }
        const home = { class: classes };
        if (filter && Object.keys(filters).length) home.filters = filters;
        return home;
    },
    homeVod() {
        const rows = postJSON('/api/v1/video/recommended', {}).data || [];
        return { list: rows.flatMap(row => (row.videos || []).map(video)) };
    },
    category(tid, pg, filter, extend = {}) {
        const params = { typeId: parseInt(tid, 10), pageNum: parseInt(pg, 10), pageSize: 40 };
        if (extend.class) params.classify = extend.class;
        for (const key of ['area', 'year', 'sortBy']) if (extend[key]) params[key] = extend[key];
        const data = postJSON('/api/v1/video/index', params).data || {};
        const count = Number(data.totalPage) || 1;
        return { page: parseInt(pg, 10), pagecount: count, limit: 40, total: count * 40, list: (data.list || []).map(video) };
    },
    detail(id) {
        const data = postForm('/api/v1/video/videoDetails', { id }).data;
        if (!data) return { list: [] };
        const names = [], urls = [];
        for (const source of data.playerSource || []) {
            if (Number(source.state) !== 1) continue;
            names.push(String(source.sourceName || ''));
            urls.push((source.episodes || []).map(e => `${e.episodeName}$${e.playerCode}${SEP}${source.sourceCode}${SEP}${Number(source.direct) || 0}${SEP}${Number(source.parse) || 0}${SEP}${source.parseUrl || ''}`).join('#'));
        }
        const counters = [0, 0];
        const labels = names.map((name, index) => {
            const group = index % 2;
            const n = ++counters[group];
            const quality = (QUALITY.find(([key]) => name.includes(key)) || [null, ''])[1];
            return `${['听风', '知秋'][group]}${n < 21 ? NUMBERS[n] : n}线${quality ? `[${quality}]` : ''}`;
        });
        return { list: [{
            vod_id: String(data.id ?? id), vod_name: String(data.name || ''), vod_pic: String(data.videoPic || ''), type_name: String(data.classify || ''),
            vod_year: String(data.year || ''), vod_area: String(data.area || ''), vod_remarks: String(data.remarks || ''), vod_actor: String(data.actor || ''),
            vod_director: String(data.director || ''), vod_content: String(data.content || ''), vod_play_from: labels.join('$$$'), vod_play_url: urls.join('$$$')
        }] };
    },
    search(wd) {
        const data = postJSON('/api/v1/video/search', { keyword: wd, pageNum: 1, pageSize: 40 }).data || {};
        return { list: (data.list || []).map(video) };
    },
    play(flag, id) {
        const [code, from = '', direct = '0', parse = '0', parseUrl = ''] = id.split(SEP);
        if (Number(direct) === 1 || isMedia(code)) return result(code);
        if (Number(parse) === 1 && parseUrl.startsWith('http')) { const found = viaParse(parseUrl, code); if (found) return found; }
        if (from) {
            const url = String(postForm('/api/v1/player/analysisUrl', { from, code }).data || '');
            if (url.startsWith('http')) return result(url);
        }
        if (Number(parse) !== 1 && parseUrl.startsWith('http')) { const found = viaParse(parseUrl, code); if (found) return found; }
        return result(code, null, 1);
    }
};
