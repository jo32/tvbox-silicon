// 独播库 (csp_Duboku): a JSON API. Every request carries sign/ssid/token built from time-seeded
// java.util.Random sequences; ids and image paths are base64 with 10-character blocks reversed.
// ext: "https://api..." or {"api"|"site": ...}
import { JavaRandom } from './_lite.js';

const HEADERS = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)', Connection: 'Keep-Alive', Referer: 'https://www.duboku.tv/' };
const PLAY_HEADERS = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36', origin: 'https://w.duboku.io', referer: 'https://w.duboku.io/' };
const FILTER = [
    { key: 'class', name: '类型', value: ['喜剧', '爱情', '恐怖', '动作', '科幻', '剧情', '悬疑', '惊悚', '古装'].map(v => ({ n: v, v })) },
    { key: 'area', name: '地区', value: ['大陆', '香港', '台湾', '韩国', '日本', '泰国'].map(v => ({ n: v, v })) },
    { key: 'year', name: '年份', value: ['2025', '2024', '2023', '2022', '2021', '2020'].map(v => ({ n: v, v })) },
    { key: 'lang', name: '语言', value: ['国语', '粤语', '韩语', '英语', '日语'].map(v => ({ n: v, v })) },
    { key: 'by', name: '排序', value: [{ n: '时间', v: '' }, { n: '人气', v: '人气' }, { n: '评分', v: '评分' }] }
];

let api = 'https://api.dbokutv.com';

function decode(value) {
    try {
        const text = String(value || '').replace(/\./g, '=');
        let out = '';
        for (let i = 0; i < text.length; i += 10) out += text.slice(i, i + 10).split('').reverse().join('');
        return Buffer.from(out, 'base64').toString('utf8');
    } catch { return ''; }
}

function randomText(length, seed, kind) {
    const random = new JavaRandom(seed);
    let chars;
    if (kind === 33) chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    else if (kind === 88) chars = 'XYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVW';
    else { chars = ''; for (let c = kind; c < kind + 62; c++) chars += String.fromCharCode(c); }
    let out = '';
    for (let i = 0; i < length; i++) out += chars.charAt(random.nextInt(chars.length));
    return out;
}

function signature() {
    const millis = Date.now(), seconds = Math.floor(millis / 1000);
    const n = new JavaRandom(seconds).nextInt(800000000) % 800000001;
    const stamp = String(millis), mixed = String(100000000 + n) + String(900000000 - n);
    let interleaved = '';
    const shared = Math.min(mixed.length, stamp.length);
    for (let i = 0; i < shared; i++) interleaved += mixed[i] + stamp[i];
    interleaved += mixed.slice(shared) + stamp.slice(shared);
    const ssid = Buffer.from(interleaved, 'utf8').toString('base64').replace(/=/g, '.');
    return `?sign=${randomText(60, 60 + seconds, 33)}&ssid=${ssid}&token=${randomText(38, seconds + 38, 88)}`;
}

function get(path, extra = '') {
    const response = globalThis.req(api + path + signature() + extra, { headers: HEADERS });
    return JSON.parse(response.content || 'null');
}

const videos = list => (list || []).map(v => ({
    vod_id: decode(v.DId), vod_name: String(v.Name || ''), vod_pic: decode(v.TnId),
    vod_remarks: 'Tag' in v ? String(v.Tag) : ('Rating' in v ? `${Number(v.Rating)}分` : '')
}));

export default {
    init(ext) {
        let value = String(ext || '').trim();
        if (value && !value.startsWith('http')) { try { const c = JSON.parse(value); value = c.api || c.site || ''; } catch { value = ''; } }
        if (value) api = value.replace(/\/+$/, '');
    },
    home() {
        const ids = ['1', '2', '3', '4', '21', '20', '13', '15', '14'], names = ['电影', '电视剧', '综艺', '动漫', '短剧', '港剧', '陆剧', '日韩剧', '台泰剧'];
        const rows = get('/home') || [];
        const filters = {};
        for (const id of ['1', '2', '13', '14', '15', '20', '21', '3', '4']) filters[id] = FILTER;
        return { class: ids.map((type_id, i) => ({ type_id, type_name: names[i] })), list: rows.flatMap(row => videos(row && row.VodList)), filters };
    },
    category(tid, pg, filter, extend = {}) {
        const path = `/vodshow/${extend.cateId || tid}-${extend.area || ''}-${extend.by || ''}-${extend.class || ''}-${extend.lang || ''}----${pg}---${extend.year || ''}`;
        return { page: parseInt(pg, 10), pagecount: 44739242, limit: 48, total: 2147483647, list: videos((get(path) || {}).VodList) };
    },
    detail(id) {
        const data = get(id) || {};
        const name = String(data.Name || '');
        const episodes = (data.Playlist || []).filter(Boolean).map(e => `${e.EpisodeName}$${decode(e.VId)}|${e.EpisodeName}|${name}`);
        return { list: [{
            vod_id: id, vod_name: name, vod_pic: decode(data.TnId), vod_year: String(data.ReleaseYear || ''), vod_content: String(data.Description || ''),
            vod_actor: Array.isArray(data.Actor) ? JSON.stringify(data.Actor) : '', vod_director: String(data.Director || ''),
            vod_play_from: '独播库', vod_play_url: episodes.join('#')
        }] };
    },
    search(wd) {
        return { list: videos(get('/vodsearch', '&wd=' + encodeURIComponent(wd))) };
    },
    play(flag, id) {
        const path = String(id).split('|')[0];
        const url = decode((get(path) || {}).HId);
        const result = { parse: 0, url, header: PLAY_HEADERS };
        if (url.includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
