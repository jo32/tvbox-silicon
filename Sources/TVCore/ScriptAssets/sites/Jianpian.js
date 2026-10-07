// 荐片 (csp_Jianpian): the jp3 app API. The API host comes from a DNS TXT record (wangerniu.<domain>), the
// image host from resourceDomainConfig. Lines are mostly direct m3u8; ftp links become tvbox-xg:ftp.
// ext: optional URL of a filters JSON (TVBox "filters" object).
const UA = 'Mozilla/5.0 (Linux; Android 9; V2196A Build/PQ3A.190705.08211809; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Mobile Safari/537.36;webank/h5face;webank/1.0;netType:NETWORK_WIFI;appVersion:416;packageName:com.jp3.xg3';
const FALLBACK = 'https://ev5356.970xw.com';
const TXT = 'https://dns.alidns.com/resolve?name=swrdsfeiujo25sw.cc&type=TXT';

let api = '', img = '', filtersURL = '';

const headers = () => ({ 'User-Agent': UA, Referer: api });
const fetchText = url => { try { return String(globalThis.req(url, { headers: headers(), timeout: 15000 }).content || ''); } catch { return ''; } };
const fetchJSON = url => { const text = fetchText(url).trim(); try { return text.startsWith('{') ? JSON.parse(text) : {}; } catch { return {}; } };
const str = v => v == null ? '' : String(v);

function host(value) {
    let text = str(value).trim();
    if (!text) return '';
    if (text.startsWith('//')) text = 'https:' + text;
    if (!/^https?:\/\//.test(text)) text = 'https://' + text;
    return text.replace(/\/+$/, '');
}
function pickImageHost(list) {
    let first = '';
    for (const candidate of str(list).split(',').map(host).filter(Boolean)) {
        first ||= candidate;
        try { const code = globalThis.req(candidate, { headers: headers(), timeout: 8000 }).code || 0; if (code > 0 && code < 500) return candidate; } catch {}
    }
    return first;
}
function picture(path) {
    let text = str(path).trim();
    if (!text || /^https?:\/\//.test(text)) return text;
    if (text.startsWith('//')) return 'https:' + text;
    if (!img) return text;
    return img + (text.startsWith('/') ? text : '/' + text);
}
const names = (list, link) => (list || []).map(c => str(c && (c.title ?? c.name))).map(n => link ? `[a=cr:{"id":"${n}/{pg}","name":"${n}"}/]${n}[/a]` : n).join(' ');
const card = d => ({ vod_id: str(d.id), vod_name: str(d.title), vod_pic: picture(d.thumbnail ?? d.path ?? d.cover_image), vod_remarks: str(d.mask) || str(d.playlist && (d.playlist.title ?? d.playlist.name)) });
const items = data => Array.isArray(data.data) ? data.data.filter(Boolean) : [];

export default {
    init(ext) {
        api = FALLBACK; img = ''; filtersURL = str(ext).trim();
        try {
            const answer = (JSON.parse(globalThis.req(TXT, {}).content || '{}').Answer || [])[0];
            for (const domain of str(answer && answer.data).replace(/"/g, '').split(',').map(s => s.trim()).filter(Boolean)) {
                api = 'https://wangerniu.' + domain;
                const config = fetchText(api + '/api/v2/settings/resourceDomainConfig');
                if (config) { img = pickImageHost(JSON.parse(config).data.imgDomain); return; }
            }
        } catch {}
    },
    home(filter) {
        const classes = items(fetchJSON(api + '/api/v2/settings/homeCategory')).filter(c => str(c.name) !== '推荐').map(c => ({ type_id: str(c.id), type_name: str(c.name) }));
        let filters = {};
        if (filter && /^https?:/.test(filtersURL)) { try { filters = JSON.parse(fetchText(filtersURL)); } catch {} }
        return { class: classes, filters };
    },
    homeVod() {
        return { list: items(fetchJSON(api + '/api/slide/list?pos_id=88')).map(d => ({ vod_id: str(d.jump_id), vod_name: str(d.title), vod_pic: picture(d.thumbnail ?? d.path ?? d.cover_image) })) };
    },
    category(tid, pg, filter, extend = {}) {
        const page = parseInt(pg, 10) || 1;
        if (String(tid).endsWith('/{pg}')) return this.search(String(tid).split('/')[0], false, pg);
        if (['50', '99', '111'].includes(String(tid))) {
            const list = items(fetchJSON(`${api}/api/dyTag/list?category_id=${tid}&page=${page}`)).flatMap(group => (group.dataList || []).filter(Boolean).map(card));
            return { page: 1, pagecount: 1, limit: list.length, total: list.length, list };
        }
        const area = extend.area ?? '0', year = extend.year ?? '0', sort = extend.by ?? 'updata';
        const list = items(fetchJSON(`${api}/api/crumb/list?fcate_pid=${tid}&area=${area}&year=${year}&type=0&sort=${sort}&page=${page}&category_id=`)).map(card);
        return { page, list };
    },
    detail(id) {
        const d = fetchJSON(`${api}/api/video/detailv2?id=${id}`).data || {};
        const sources = (d.source_list_source || []).filter(Boolean);
        const vod = {
            ...card(d), vod_id: str(d.id) || String(id),
            vod_play_from: sources.map(s => str(s.name)).join('$$$'),
            vod_play_url: sources.map(s => (s.source_list || []).filter(Boolean).map(e => `${str(e.source_name)}$${str(e.url).replace(/ftp/g, 'tvbox-xg:ftp')}`).join('#')).join('$$$'),
            vod_year: str(d.year), vod_area: str(d.area), type_name: names(d.types, false), vod_actor: names(d.actors, true),
            vod_director: names(d.directors, true), vod_content: str(d.description).replace(/　/g, '')
        };
        return { list: [vod] };
    },
    search(wd, quick, pg) {
        const page = parseInt(pg, 10) || 1;
        const list = items(fetchJSON(`${api}/api/v2/search/videoV2?key=${encodeURIComponent(wd)}&category_id=88&page=${page}&pageSize=20`)).map(card);
        return { page, list };
    },
    play(flag, id) {
        return { parse: 0, url: String(id || ''), header: headers() };
    }
};
