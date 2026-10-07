// 光影 / 奶酪 (fty csp_T4Guard): a TVBox type-1 CMS JSON API (api.php/provide/vod) described by the (encrypted) ext:
// {"siteUrl", "type", "categories": [kept type names], "rmCategories": [dropped], "playUrl": parse prefix, "searchMode"}.
// Adult categories are always dropped. The JAR's web search mode needs the site's captcha; the port searches the API.
import { ftyConfig } from './_fty.js';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const ADULT = ['伦理', '三级', '福利', '色情', '午夜', '两性'];

let api = '', keep = [], drop = [], playUrl = '';

const withParams = params => api + (api.includes('?') ? '&' : '?') + Object.entries(params).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
const get = params => { const url = Object.keys(params).length ? withParams(params) : api; try { return JSON.parse(globalThis.req(url, { headers: { 'User-Agent': UA }, timeout: 15000 }).content || '{}'); } catch { return {}; } };
const adult = text => ADULT.some(word => String(text || '').includes(word));
// CMS APIs send numeric ids; the app reads ids as strings.
const clean = list => (list || []).filter(v => v && !adult(v.vod_class) && !adult(v.type_name) && String(v.vod_name || '').trim()).map(v => ({ ...v, vod_id: String(v.vod_id), type_id: v.type_id == null ? v.type_id : String(v.type_id) }));

export default {
    init(ext) {
        const config = ftyConfig(ext);
        api = String(config.siteUrl || '').trim();
        if (!api) throw new Error('T4: ext has no siteUrl: ' + String(typeof ext === 'string' ? ext : JSON.stringify(ext)).slice(0, 80));
        keep = (config.categories || []).map(String);
        drop = (config.rmCategories || []).map(String);
        playUrl = String(config.playUrl || '');
    },
    home(filter) {
        const data = get(filter ? { filter: 'true' } : {});
        const classes = (data.class || []).filter(c => c && !adult(c.type_name) && !drop.includes(String(c.type_name)) && (!keep.length || keep.includes(String(c.type_name)))).map(c => ({ ...c, type_id: String(c.type_id) }));
        const result = { class: classes };
        if (filter && data.filters) result.filters = data.filters;
        result.list = clean(get({ ac: 'detail' }).list);
        return result;
    },
    category(tid, pg, filter, extend = {}) {
        const params = { ac: 'detail', t: tid, pg: pg || '1' };
        for (const [key, value] of Object.entries(extend || {})) if (value) params[key] = value;
        const data = get(params);
        return { ...data, list: clean(data.list) };
    },
    detail(ids) {
        const data = get({ ac: 'detail', ids });
        return { ...data, list: clean(data.list) };
    },
    search(wd, quick, pg) {
        const data = get({ ac: 'detail', pg: pg || '1', wd });
        return { ...data, list: clean(data.list) };
    },
    play(flag, id) {
        const url = String(id || '');
        if (playUrl) return { parse: 1, playUrl, url };
        if (/\.(m3u8|mp4|flv)(\?|$)/i.test(url) || /\.m3u8/i.test(url)) return { parse: 0, url };
        return { parse: /^https?:\/\//.test(url) ? 1 : 0, url };
    }
};
