// 听世界 (csp_TingShijie, fty csp_Tingshu275Guard): an audiobook app API; chapter URLs need md5(md5(t + SALT) + SALT).
// ext: API base (optional; otherwise read from the published config).
import { md5 } from './_lite.js';

const UA = 'TingShiJie/1.8.8 (m.i275.com)';
const SALT = 'J9gSpfUlzYxE8Hn5IXiGaD2jVMrwAm0K';
const DEFAULT = 'https://app.365ting.com/listen/Apitzg2025/';
const CLASSES = [['6', '玄幻奇幻'], ['7', '都市言情'], ['8', '宫斗女频'], ['9', '官场商战'], ['10', '武侠仙侠'], ['11', '刑侦推理'], ['12', '探险科幻'], ['13', '重生穿越'], ['14', '恐怖惊悚'], ['15', '文学历史'], ['49', '两性情感']];

let base = DEFAULT;

function normalize(address) {
    let value = String(address || DEFAULT).trim();
    const colon = value.indexOf(':');
    const scheme = colon > 0 ? value.slice(0, colon) : 'https';
    if (colon > 0) value = value.slice(Math.min(colon + 3, value.length));
    return scheme + '://' + value.replace(/\/+$/, '') + '/';
}

const api = path => { try { return JSON.parse(globalThis.req(base + path, { headers: { 'User-Agent': UA } }).content || '{}'); } catch { return {}; } };
const books = list => (list || []).filter(Boolean).map(b => ({ vod_id: String(b.id), vod_name: String(b.bookTitle || ''), vod_pic: String(b.bookImage || ''), vod_remarks: String(b.bookAnchor || '') }));
const category = (id, page) => { const data = api(`appHomeByCategory?categoryId=${id}&page=${page}&size=120`); return data.status === 0 ? books(data.data) : []; };

export default {
    init(ext) {
        if (ext) { base = normalize(ext); return; }
        base = DEFAULT;
        // The JAR versions publish the same config on different hosts (csp_TingShijie, fty csp_Tingshu275Guard).
        for (const host of ['101.43.48.231', '117.72.112.234']) {
            try {
                const text = (globalThis.req(`http://${host}:8090/config/tingchina2025.txt`, { headers: { 'User-Agent': UA }, timeout: 8000 }).content || '').trim();
                if (text.startsWith('http')) { base = normalize(text); return; }
            } catch {}
        }
    },
    home() { return { class: CLASSES.map(([type_id, type_name]) => ({ type_id, type_name })), list: category('6', '1') }; },
    category(tid, pg) {
        const page = parseInt(pg, 10) || 1;
        return { page, pagecount: 100, limit: 120, total: 12000, list: category(tid, page) };
    },
    detail(id) {
        const data = api('book?bookId=' + id);
        const book = data.status === 0 && data.data && data.data.bookData;
        if (!book) return { list: [] };
        const chapters = [];
        const pages = Math.max(1, Math.ceil((Number(book.count) || 0) / 1000));
        for (let page = 1; page <= pages; page++) {
            const list = api(`chapter?size=1000&page=${page}&sort=asc&bookId=${id}`);
            if (list.status !== 0) continue;
            for (const c of ((list.data || {}).list || [])) if (c) chapters.push(`${c.title ?? c.position}$${id}|${c.chapterId}`);
        }
        return { list: [{ vod_id: id, vod_name: String(book.bookTitle || ''), vod_pic: String(book.bookImage || ''), vod_remarks: String(book.bookAnchor || ''), vod_content: String(book.bookDesc || ''), vod_play_from: '听世界', vod_play_url: chapters.join('#') }] };
    },
    search(wd) {
        const data = api(`appSearch?client=babala-android&search=${encodeURIComponent(wd)}&app_token=abcSEARCH-2025`);
        return { list: data.status === 0 ? books((data.data || {}).bookData) : [] };
    },
    play(flag, id) {
        const [book, chapter] = String(id).split('|');
        if (!chapter) return { parse: 0, url: '' };
        const time = String(Date.now());
        const sign = md5(md5(time + SALT) + SALT);
        const data = api(`AppGetChapterUrl2023?timeStamp=${time}&uid=&chapterId=${chapter}&addItParapet=${sign}&bookId=${book}`);
        return { parse: 0, url: data.status === 0 ? String(data.src || '') : '', header: { 'User-Agent': UA } };
    }
};
