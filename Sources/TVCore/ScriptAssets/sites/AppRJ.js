// 热播APP (csp_AppRJ): a v3 app API; every call is a multipart POST signed with md5(SALT + timestamp).
// Episodes carry the line's parse services; playback asks each one until it yields a media address.
// ext: {"url": "http://v.rbotv.cn"}
import { md5, randomHex } from './_lite.js';

const SALT = '7gp0bnd2sr85ydii2j32pcypscoc4w6c7g5spl';
const MEDIA = /https?:\/\/[^\s]+\.(m3u8|mp4|flv|avi|mkv|rmvb|wmv|mpg|mpeg|mov|ts)/;

let site = '';

const now = () => String(Math.floor(Date.now() / 1000));
const sign = time => md5(SALT + time);
/** Restore the scheme separator the way the spider does ("http:xx" or "xx" -> "http://xx"). */
function scheme(address) {
    const colon = address.indexOf(':');
    const protocol = colon > 0 ? address.slice(0, colon) : 'https';
    const rest = colon > 0 ? address.slice(Math.min(colon + 3, address.length)) : address;
    return protocol + '://' + rest;
}

function api(path, fields) {
    const time = now();
    const all = { timestamp: time, sign: sign(time), ...fields };
    const boundary = 'okhttp' + randomHex(12);
    const body = Object.entries(all).map(([k, v]) => `--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v ?? ''}\r\n`).join('') + `--${boundary}--\r\n`;
    const response = globalThis.req(site + '/v3/' + path, { method: 'POST', body, headers: { 'User-Agent': 'okhttp-okgo/jeasonlzy', 'Content-Type': 'multipart/form-data; boundary=' + boundary } });
    if (response.code !== 200) return {};
    try { return JSON.parse(response.content).data || {}; } catch { return {}; }
}

const videos = list => (list || []).map(v => ({ vod_id: String(v.vod_id), vod_name: String(v.vod_name || ''), vod_pic: String(v.vod_pic || v.vod_pic_thumb || ''), vod_remarks: String(v.vod_remarks || '') }));
const FILTER_NAMES = { extend: '类型', area: '地区', year: '年份', lang: '语言' };

export default {
    init(ext) {
        // fty's csp_AppTTGuard passes an encrypted ext the port cannot read; it serves the same host.
        let config = ext;
        if (typeof config === 'string') { try { config = JSON.parse(config || '{}'); } catch { config = {}; } }
        site = scheme(String((config && config.url) || 'http://v.rbotv.cn'));
    },
    home(filter) {
        const types = api('type/top_type', {}).list || [];
        const classes = [], filters = {};
        for (const type of types) {
            classes.push({ type_id: String(type.type_id), type_name: String(type.type_name) });
            if (!filter) continue;
            const groups = [];
            for (const key of Object.keys(type)) {
                if (!FILTER_NAMES[key] || !Array.isArray(type[key])) continue;
                const values = type[key].filter(v => String(v).length > 1).map(v => ({ n: String(v), v: String(v) }));
                if (values.length > 1) groups.push({ key: key.replace('extend', 'class'), name: FILTER_NAMES[key], value: values });
            }
            filters[type.type_id] = groups;
        }
        return { class: classes, list: [], filters };
    },
    category(tid, pg, filter, extend = {}) {
        const fields = { type_id: tid, limit: '12', page: pg };
        for (const key of ['area', 'class', 'lang', 'year']) if (extend[key]) fields[key] = extend[key];
        return { list: videos(api('home/type_search', fields).list), page: Number(pg), pagecount: 9999, limit: 12, total: 999999 };
    },
    detail(id) {
        const data = api('home/vod_details', { vod_id: id });
        const name = String(data.vod_name || '');
        const froms = [], urls = [];
        for (const line of data.vod_play_list || []) {
            const parses = (line.parse_urls || []).map(p => p + '@').join('');
            const items = (line.urls || []).map(u => `${u.name}$${parses}|${u.url}|${line.ua || ''}||${name}|${u.nid ?? ''}`);
            froms.push(String(line.name));
            urls.push(items.join('#'));
        }
        return { list: [{
            vod_id: id, vod_name: name, vod_pic: String(data.vod_pic || data.vod_pic_thumb || ''), vod_remarks: String(data.vod_remarks || ''),
            vod_content: String(data.vod_content || '').replace(/[^一-龥　-〿＀-￯]/g, ''), vod_year: String(data.vod_year || ''),
            vod_actor: String(data.vod_actor || ''), vod_director: String(data.vod_director || ''), type_name: String(data.vod_class || ''),
            vod_play_from: froms.join('$$$'), vod_play_url: urls.join('$$$')
        }] };
    },
    search(wd) {
        return { list: videos(api('home/search', { keyword: wd, limit: '12', page: '1' }).list) };
    },
    play(flag, id) {
        let parts = id.split('|');
        if (parts.length === 5) parts = `${parts[0]}|${parts[1]}|${parts[2]}||${parts[3]}|${parts[4]}`.split('|');
        const parses = parts[0];
        let url = parts[1];
        let ua = parts[2];
        for (const parse of (parses || '').split('@')) {
            if (!parse) continue;
            try {
                const time = now();
                const response = globalThis.req(scheme(parse) + url + '&sign=' + sign(time) + '&timestamp=' + time, { headers: { Referer: '' } });
                const answer = JSON.parse(response.content);
                url = String(answer.url || '');
                if (answer.UA) ua = String(answer.UA);
                if (!/url=http|\.js|\.css|\.html/.test(url) && MEDIA.test(url)) break;
            } catch { /* next parse service */ }
        }
        if (!url.startsWith('http')) return { parse: 0, url: '' };
        const result = { parse: 0, url: scheme(url) };
        if (ua) result.header = { 'User-Agent': ua };
        return result;
    }
};
