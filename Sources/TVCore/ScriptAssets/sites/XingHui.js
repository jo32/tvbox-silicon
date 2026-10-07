// 星绘动漫 (csp_XingHui): the author's xinghui.php bridge names each upstream request (prepare) and
// parses the fetched body (consume). ext: "https://.../xinghui.php" or {"url"|"api": ...}
import { Bridge } from './_bridge.js';

const KEY = 'yvBYNvdSkWp7kHTu';
const IV = 'axoCiSECxsah9Ur2';
const ACCESS = ['access', 'c2e3e71fb353fd900883dcd0b3ef11a4026a1ea07ede5ca4'];
const UA = 'Dalvik/2.1.0 (Linux; U; Android)';

let bridge;

function call(scene, params = {}) {
    const target = bridge.send({ action: 'prepare', scene, params, ua: UA, client_time: Math.floor(Date.now() / 1000) });
    const reply = bridge.perform({ method: 'GET', url: target.url, headers: target.headers || {} });
    if (reply.status < 200 || reply.status >= 300) throw new Error('HTTP ' + reply.status);
    return bridge.send({ action: 'consume', scene, body: reply.body });
}

const videos = list => (list || []).filter(Boolean).map(v => ({ vod_id: String(v.id ?? ''), vod_name: String(v.name || ''), vod_pic: String(v.pic || ''), vod_remarks: String(v.remarks || '') }));
function page(pg, data) {
    const total = Math.min(Number(data.total) || 0, 2147483647);
    const list = videos(data.list);
    return { page: pg, pagecount: Math.max(1, Math.ceil(total / 20)), limit: 20, total: Math.max(total, list.length), list };
}
function group(key, name, values) {
    const items = [...new Set(values.map(v => v.trim()).filter(Boolean))].map(v => { const at = v.indexOf('='); return at < 0 ? { n: v, v } : { n: v.slice(0, at), v: v.slice(at + 1) }; });
    if (!items.length) return null;
    return { key, name, value: key === 'order' ? items : [{ n: '全部', v: '' }, ...items] };
}
const packed = text => Buffer.from(text, 'utf8').toString('base64url');

export default {
    init(ext) {
        let address = String(ext || '').trim();
        if (address.startsWith('{')) { const c = JSON.parse(address); address = String(c.url || c.api || '').trim(); }
        if (!address.startsWith('http')) throw new Error('星绘服务地址未配置');
        bridge = new Bridge({ php: address.replace(/\/+$/, ''), site: '', key: KEY, iv: IV, access: ACCESS, label: 'xinghui' });
    },
    home(filter) {
        const items = call('nav').items || [];
        const classes = [], filters = {};
        for (const item of items) {
            if (!item) continue;
            const id = String(item.id ?? '');
            classes.push({ type_id: id, type_name: String(item.name || '') });
            if (!filter) continue;
            const f = item.filters || {};
            const split = v => (v ? String(v).split(',') : []);
            filters[id] = [group('order', '排序', ['最新=time', '热门=hits', '高分=score']), group('class', '类型', split(f.class)), group('area', '地区', split(f.area)), group('lang', '语言', split(f.lang)), group('year', '年份', split(f.year))].filter(Boolean);
        }
        return { class: classes, filters };
    },
    homeVod() { return { list: videos(call('home').list) }; },
    category(tid, pg, filter, extend = {}) {
        const p = Math.max(1, parseInt(pg, 10) || 1);
        const params = { tid, page: p, order: extend.order || 'time' };
        for (const key of ['class', 'area', 'lang', 'year']) if (extend[key]) params[key] = extend[key];
        return page(p, call('category', params));
    },
    detail(id) {
        const data = call('detail', { id });
        const vod = data.vod;
        if (!vod) return { list: [] };
        const froms = [], urls = [];
        for (const source of data.sources || []) {
            if (!source) continue;
            const episodes = (call('episodes', { id, from: String(source.code || '') }).episodes || []).filter(e => e && e.url).map(e => {
                const name = String(e.name || '').replace(/[#$]/g, ' ').trim() || '播放';
                return `${name}$${e.parse ? 'p:' : 'd:'}${packed(String(e.url))}`;
            });
            if (episodes.length) { froms.push(froms.length ? `星绘${froms.length + 1}` : '星绘'); urls.push(episodes.join('#')); }
        }
        if (!urls.length) return { list: [], msg: '暂无播放数据' };
        return { list: [{
            vod_id: String(vod.id ?? id), vod_name: String(vod.name || ''), vod_pic: String(vod.pic || ''), vod_remarks: String(vod.remarks || ''), vod_year: String(vod.year || ''),
            vod_area: String(vod.area || ''), vod_actor: String(vod.actor || ''), vod_director: String(vod.director || ''), vod_content: String(vod.content || ''),
            vod_play_from: froms.join('$$$'), vod_play_url: urls.join('$$$')
        }] };
    },
    search(wd, quick, pg) {
        const p = Math.max(1, parseInt(pg, 10) || 1);
        return page(p, call('search', { text: wd, page: p }));
    },
    play(flag, id) {
        let url = id, needsResolve = false;
        if (id && id.length > 2 && id[1] === ':') {
            try { url = Buffer.from(id.slice(2).replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'); needsResolve = id.startsWith('p:'); } catch { url = id; }
        }
        if (needsResolve) {
            url = String(call('resolve', { url }).url || '');
            if (!url) return { parse: 0, url: '', msg: '播放地址解析失败' };
        }
        const result = { parse: 0, url, header: { 'User-Agent': UA } };
        if (url.includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
