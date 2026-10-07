// 布谷音乐 (csp_Buguyy): a music JSON API. Songs seen in lists are cached so details need no request;
// playback asks /api/geturl, with the geturl2.php fallback the site's error message points to.
const SITE = 'https://www.buguyy.top';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';
const HEADERS = { 'User-Agent': UA, Referer: SITE + '/', Accept: 'application/json, text/plain, */*' };
const CLASSES = [['new', '最新'], ['hot', '人气'], ['random', '精选'], ['mix', '音乐串烧'], ['album', '音乐合集']];
const ICON = SITE + '/apple-touch-icon.png';

const songs = new Map();
const field = (o, k) => o && o[k] != null ? String(o[k]) : '';
const getJSON = url => { try { return JSON.parse(globalThis.req(url, { headers: HEADERS }).content || '{}'); } catch { return {}; } };

function fetchList(path) {
    const data = getJSON(SITE + path);
    const list = [];
    for (const song of data.data || []) {
        const id = field(song, 'id'), title = field(song, 'title');
        if (!id || !title) continue;
        let pic = field(song, 'picurl');
        if (!pic || pic.toLowerCase() === 'null') pic = ICON;
        list.push({ vod_id: id, vod_name: title, vod_pic: pic, vod_remarks: field(song, 'singer') });
        songs.set(id, song);
    }
    return { list, page: Number(data.currentPage) || 1, pagecount: Math.max(Number(data.totalPages) || 1, 1), total: Math.max(Number(data.totalCount ?? data.count) || list.length, list.length) };
}

const lyrics = text => !text || text.includes('歌词获取失败') ? '' : text.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, '').replace(/\r\n?/g, '\n').trim();

export default {
    home(filter) {
        const classes = CLASSES.map(([type_id, type_name]) => ({ type_id, type_name }));
        const home = { class: classes, list: fetchList('/api/newlist').list };
        if (filter) {
            const group = [{ key: 'type', name: '类型', value: CLASSES.map(([v, n]) => ({ n, v })) }];
            home.filters = {};
            for (const c of classes) home.filters[c.type_id] = group;
        }
        return home;
    },
    category(tid, pg, filter, extend = {}) {
        const type = extend.type || tid;
        const page = Math.max(parseInt(pg, 10) || 1, 1);
        const path = type === 'hot' ? '/api/hotlist' : type === 'random' ? '/api/random' : type === 'mix' ? `/api/heji?cid=10&page=${page}` : type === 'album' ? `/api/heji?cid=11&page=${page}` : '/api/newlist';
        const result = fetchList(path);
        return { page: result.page > 0 ? result.page : page, pagecount: result.pagecount, limit: 50, total: result.total, list: result.list };
    },
    detail(id) {
        const song = songs.get(id);
        const title = song ? field(song, 'title') : id, singer = song ? field(song, 'singer') : '';
        let pic = song ? field(song, 'picurl') : '';
        if (!pic || pic.toLowerCase() === 'null') pic = ICON;
        return { list: [{
            vod_id: id, vod_name: title, vod_pic: pic, vod_actor: singer, vod_remarks: singer, vod_content: lyrics(song ? field(song, 'about') : ''),
            vod_play_from: '布谷音乐', vod_play_url: `${singer ? `${title} - ${singer}` : title}$${id}`
        }] };
    },
    search(wd) {
        const result = fetchList('/api/search?keyword=' + encodeURIComponent(wd));
        return { page: 1, pagecount: 1, limit: 50, total: result.total, list: result.list };
    },
    play(flag, id) {
        let data = getJSON(`${SITE}/api/geturl?id=${encodeURIComponent(id)}`);
        if (!data.success) {
            const fallback = /geturl2\.php\?id=(\d+)/.exec(field(data, 'error'));
            if (fallback) {
                const second = getJSON('http://a.buguyy.top/newapi/geturl2.php?id=' + fallback[1]);
                if (Number(second.code) === 200 && second.data && field(second.data, 'url').startsWith('http')) data = { ...second.data, success: true };
            }
        }
        const url = field(data, 'url');
        if (!data.success || !url.startsWith('http') || url.toLowerCase() === 'none') return { parse: 0, url: '', msg: field(data, 'message') || '播放地址获取失败' };
        const result = { parse: 0, url, header: { 'User-Agent': UA } };
        const lrc = lyrics(field(data, 'lrc')) || lyrics(songs.has(id) ? field(songs.get(id), 'about') : '');
        if (lrc) result.lrc = lrc;
        return result;
    }
};
