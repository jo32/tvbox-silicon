// Hema (河马) short dramas from its website kuaikaw.cn: genres, lists, search and the episodes it gives away.
// Pages and fields follow jackotom/hongguo-drama v4.1 src/native/hema.js; see hongguo/NOTICE.txt.
const ORIGIN = 'https://www.kuaikaw.cn';
const ID = /^\d{1,30}$/;
const GENRE = /^\d{1,30}(?:-\d{1,30}){0,15}$/;
const headers = { 'User-Agent': 'Mozilla/5.0', pname: 'www.kuaikaw.cn', Origin: ORIGIN, Referer: `${ORIGIN}/` };
let labels = {};
let genreCache = null;
const fail = key => { throw new Error(labels[key] || 'Hema is temporarily unavailable. Please try again.'); };
const text = value => String(value ?? '').replace(/<[^>]*>/g, '').trim();
const https = value => {
    try { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password ? url.href : ''; } catch { return ''; }
};

function fetchText(path, body) {
    const reply = globalThis.req(ORIGIN + path, body
        ? { method: 'POST', headers: { ...headers, Accept: 'application/json', 'Content-Type': 'application/json' }, body: JSON.stringify(body), timeout: 10000, redirect: false }
        : { headers: { ...headers, Accept: 'text/html' }, timeout: 10000, redirect: false });
    if (reply.code !== 200 || !reply.content || reply.content.length > 8 * 1024 * 1024) fail('unavailable');
    return reply.content;
}

// The site is a Next.js app: each page's data is in its __NEXT_DATA__ script, read as JSON and never run.
export function pageData(html) {
    const match = html.match(/<script\b[^>]*\bid=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)<\/script>/i);
    let data;
    try { data = JSON.parse(match?.[1]).props.pageProps; } catch { fail('changed'); }
    if (!data || typeof data !== 'object') fail('changed');
    return data;
}

// The cover URL asks for a 200-pixel thumbnail; without that it is the full picture.
const cover = value => https(String(value ?? '').replace(/[?&]?imageView2\/[^&]*/, ''));

function card(book) {
    return { vod_id: String(book.bookId), vod_name: text(book.bookName), vod_pic: cover(book.coverWap),
        vod_remarks: Number(book.totalChapterNum) > 0 ? (labels.episodes || '%@ Episodes').replace('%@', String(Number(book.totalChapterNum))) : '' };
}

export function cards(books) {
    const seen = new Set();
    return (Array.isArray(books) ? books : []).filter(book => book && ID.test(String(book.bookId ?? '')) && text(book.bookName))
        .map(card).filter(item => !seen.has(item.vod_id) && seen.add(item.vod_id));
}

export function genres(data) {
    const seen = new Set(['0']);
    const items = (Array.isArray(data.typeThreeList) ? data.typeThreeList : [])
        .filter(item => Array.isArray(item?.typeThreeIds) && item.typeThreeIds.length > 0 && item.typeThreeIds.length <= 16
            && item.typeThreeIds.every(id => ID.test(String(id))) && text(item.name))
        .map(item => ({ type_id: item.typeThreeIds.join('-'), type_name: text(item.name) }))
        .filter(item => !seen.has(item.type_id) && seen.add(item.type_id));
    return [{ type_id: '0', type_name: labels.all || 'All' }, ...items];
}

function loadGenres() {
    if (!genreCache || genreCache.expires < Date.now()) genreCache = { items: genres(pageData(fetchText('/browse'))), expires: Date.now() + 300000 };
    return genreCache.items;
}

export function browse(html, genre, page) {
    const data = pageData(html);
    if (!Array.isArray(data.bookList) || Number(data.page) !== page || String(data.typeThreeId || '0') !== genre) fail('changed');
    const list = cards(data.bookList);
    // Genre totals aren't given; a link to the next page is.
    const more = list.length > 0 && new RegExp(`<a\\b[^>]*\\shref=["']/browse/${genre}/${page + 1}["']`).test(html);
    return { list, page, pagecount: more ? page + 1 : page };
}

export function detail(data, id) {
    const book = data.bookInfoVo;
    if (String(book?.bookId) !== id || !Array.isArray(data.chapterList)) fail('changed');
    const chapters = data.chapterList.filter(chapter => ID.test(String(chapter?.chapterId ?? '')) && (chapter.bookId == null || String(chapter.bookId) === id))
        .sort((a, b) => (Number(a.chapterIndex) || 0) - (Number(b.chapterIndex) || 0));
    // Only the episodes Hema gives away (isCharge "0"); the rest are paid.
    const free = chapters.filter(chapter => chapter.isCharge === '0' && mediaURL(chapter));
    const video = { ...card(book), vod_content: text(book.introduction),
        vod_actor: [book.actor, book.actress].map(text).filter(Boolean).join(','),
        type_name: (Array.isArray(book.bookTypeThree) ? book.bookTypeThree : []).map(tag => text(tag?.name)).filter(Boolean).slice(0, 4).join(',') };
    if (free.length < chapters.length) video.vod_remarks = (labels.free || '%@ of %@ episodes free').replace('%@', String(free.length)).replace('%@', String(chapters.length));
    if (free.length) {
        video.vod_play_from = labels.name || 'Hema';
        video.vod_play_url = free.map(chapter => `${(labels.episode || 'Episode %@').replace('%@', String(Number(chapter.chapterIndex) || 0))}$${id}/${chapter.chapterId}`).join('#');
    }
    return { list: [video] };
}

const mediaURL = chapter => https(chapter?.chapterVideoVo?.mp4720p) || https(chapter?.chapterVideoVo?.mp4);

export default {
    init(ext) { labels = typeof ext === 'string' ? JSON.parse(ext || '{}') : ext || {}; },
    home() { return { class: loadGenres() }; },
    homeVod() { return this.category('0', 1); },
    category(tid, pg) {
        const genre = String(tid || '0'), page = Math.max(1, parseInt(pg, 10) || 1);
        if (!GENRE.test(genre)) fail('changed');
        return browse(fetchText(genre === '0' && page === 1 ? '/browse' : `/browse/${genre}${page > 1 ? `/${page}` : ''}`), genre, page);
    },
    search(query, quick, pg) {
        const page = Math.max(1, parseInt(pg, 10) || 1);
        const reply = fetchText('/seo/video/6007', { sourceType: 1, keyword: String(query).trim(), index: page });
        let data;
        try { data = JSON.parse(reply); } catch { fail('changed'); }
        if (data?.retCode !== 0 || !Array.isArray(data.data?.bookList)) fail('changed');
        const list = cards(data.data.bookList);
        return { list, page, pagecount: data.data.isMore === 1 && list.length ? page + 1 : page };
    },
    detail(id) { if (!ID.test(String(id))) fail('changed'); return detail(pageData(fetchText(`/drama/${id}`)), String(id)); },
    play(flag, address) {
        const [id, chapterId, extra] = String(address).split('/');
        if (!ID.test(id || '') || !ID.test(chapterId || '') || extra !== undefined) fail('changed');
        // Read the page again: whether an episode is free can change.
        const data = pageData(fetchText(`/drama/${id}`));
        if (String(data.bookInfoVo?.bookId) !== id || !Array.isArray(data.chapterList)) fail('changed');
        const chapter = data.chapterList.find(item => String(item?.chapterId) === chapterId);
        const url = chapter?.isCharge === '0' ? mediaURL(chapter) : '';
        if (!url) fail(chapter ? 'locked' : 'changed');
        return { parse: 0, url, header: { 'User-Agent': 'Mozilla/5.0' } };
    },
};
