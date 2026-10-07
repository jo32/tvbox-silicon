// 剧圈 / 咕咕 (fty csp_AppSxGuard): the "getappapi" app API. ext (encrypted) is {"host", "key"}; replies carry
// data = base64(AES-128-CBC(json)) with key = iv = ext key, and requests are signed with
// app-api-verify-sign = AES(unix seconds). Lines with a parse API resolve through index/vodParse (url sent encrypted).
import { ftyConfig } from './_fty.js';
import { aesEncrypt, aesDecrypt, formBody } from './_lite.js';

let host = '', key = '', types = [];
const HEADERS = { 'app-ui-mode': 'light', 'app-version-code': '113', 'app-user-device-id': 'au008bi9if8524e0klt9o4e24q1qfbf7', 'User-Agent': 'okhttp/3.14.9' };

function call(action, form = {}) {
    const now = String(Math.floor(Date.now() / 1000));
    const headers = { ...HEADERS, 'app-api-verify-time': now, 'app-api-verify-sign': aesEncrypt(now, key, key), 'Content-Type': 'application/x-www-form-urlencoded' };
    const reply = JSON.parse(globalThis.req(`${host}/api.php/getappapi.${action}`, { method: 'POST', headers, body: formBody(form), timeout: 20000 }).content || '{}');
    if (!reply.data) throw new Error(String(reply.msg || `${action} returned no data`));
    return JSON.parse(aesDecrypt(reply.data, key, key));
}
const card = v => ({ vod_id: String(v.vod_id), vod_name: String(v.vod_name || ''), vod_pic: String(v.vod_pic || ''), vod_remarks: String(v.vod_remarks || '') });
const cards = list => (list || []).filter(v => v && v.vod_id != null).map(card);

export default {
    init(ext) {
        const config = ftyConfig(ext);
        host = String(config.host || '').replace(/\/+$/, '');
        key = String(config.key || '');
        if (!host || !key) throw new Error('AppSx: ext has no host/key');
        types = [];
    },
    home(filter) {
        const data = call('index/initV119');
        types = (data.type_list || []).filter(t => t && Number(t.type_id) !== 0);
        const result = { class: types.map(t => ({ type_id: String(t.type_id), type_name: String(t.type_name) })), list: cards(data.recommend_list) };
        if (filter) {
            result.filters = {};
            for (const t of types) {
                result.filters[String(t.type_id)] = (t.filter_type_list || []).filter(f => f && (f.list || []).length).map(f => ({
                    key: String(f.name), name: { class: '类型', area: '地区', lang: '语言', year: '年份', sort: '排序' }[f.name] || String(f.name),
                    value: f.list.map(v => ({ n: String(v), v: String(v) }))
                }));
            }
        }
        return result;
    },
    category(tid, pg, filter, extend = {}) {
        const page = parseInt(pg, 10) || 1;
        const form = { area: '全部', year: '全部', type_id: String(tid), page: String(page), sort: '全部', lang: '全部', class: '全部' };
        for (const [k, v] of Object.entries(extend || {})) if (v) form[k] = v;
        const list = cards(call('index/typeFilterVodList', form).recommend_list);
        return { page, pagecount: list.length ? page + 1 : page, limit: list.length, total: list.length ? (page + 1) * list.length : 0, list };
    },
    detail(id) {
        const data = call('index/vodDetail', { vod_id: String(id) });
        const v = data.vod || {};
        const froms = [], urls = [];
        for (const line of data.vod_play_list || []) {
            const info = line.player_info || {};
            const episodes = (line.urls || []).filter(u => u && u.url).map(u => `${String(u.name || '').replace(/[#$]/g, ' ')}$${[u.url, info.parse || '', info.player_parse_type || '', u.token || ''].map(encodeURIComponent).join('@')}`);
            if (episodes.length) { froms.push(String(info.show || `线路${froms.length + 1}`).trim()); urls.push(episodes.join('#')); }
        }
        return { list: [{
            vod_id: String(v.vod_id || id), vod_name: String(v.vod_name || ''), vod_pic: String(v.vod_pic || ''), vod_remarks: String(v.vod_remarks || ''),
            vod_year: String(v.vod_year || ''), vod_area: String(v.vod_area || ''), type_name: String(v.vod_class || ''), vod_actor: String(v.vod_actor || ''),
            vod_director: String(v.vod_director || ''), vod_content: String(v.vod_content || v.vod_blurb || '').replace(/<[^>]+>/g, '').trim(),
            vod_play_from: froms.join('$$$'), vod_play_url: urls.join('$$$')
        }] };
    },
    search(wd, quick, pg) {
        return { list: cards(call('index/searchList', { keywords: String(wd), type_id: '0', page: String(parseInt(pg, 10) || 1) }).search_list) };
    },
    play(flag, id) {
        const [url, parse, parseType, token] = String(id).split('@').map(decodeURIComponent);
        const header = { 'User-Agent': 'Mozilla/5.0 (Linux; Android 12; Pixel 6 Build/SKQ1.211113.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36' };
        if (parse && !/\.(m3u8|mp4)(\?|$)/i.test(url || '')) {
            try {
                // The episode address is sent AES-encrypted, like the app does.
                const data = call('index/vodParse', { parse_api: parse, url: aesEncrypt(url, key, key), player_parse_type: parseType || '1', token: token || '' });
                let found = String(data.play_url || data.url || '');
                if (!found && data.json) { try { found = String(JSON.parse(data.json).url || ''); } catch {} }
                if (found) return { parse: 0, url: found, header: { 'User-Agent': 'okhttp/3.14.9' } };
            } catch {}
            return { parse: 1, url: url || '', header };
        }
        return { parse: 0, url: url || '', header };
    }
};
