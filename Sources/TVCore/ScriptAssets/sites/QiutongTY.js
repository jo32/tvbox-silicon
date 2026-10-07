// 球通体育 (csp_QiutongTY): a live-room JSON API; rooms expose push (flv) and pull (m3u8) addresses.
// ext: "https://..." or {"api"|"site": ...}
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
const HEADERS = { 'User-Agent': UA, Accept: 'application/json, text/plain, */*', Referer: 'https://qiu.tong/' };

let api = 'https://aapi2.xbncs.com/api';

const room = path => { try { return JSON.parse(globalThis.req(`${api}/room/${path}`, { headers: HEADERS }).content || '{}').data || null; } catch { return null; } };
const field = (object, name) => object && name in object && String(object[name]) !== 'null' ? String(object[name]) : '';
const b64 = text => Buffer.from(String(text), 'utf8').toString('base64');

export default {
    init(ext) {
        let value = String(ext || '').trim();
        if (value && !value.startsWith('http')) { try { const c = JSON.parse(value); value = c.api || c.site || ''; } catch { value = ''; } }
        if (value) api = value.replace(/\/+$/, '');
    },
    home() { return { class: [['-1', '全部'], ['1', '足球'], ['2', '篮球'], ['11', '电竞']].map(([type_id, type_name]) => ({ type_id, type_name })), list: [] }; },
    category(tid, pg, filter, extend = {}) {
        const nav = extend.navId || (tid === '-1' ? '' : tid);
        const data = room(`page?roomType=&navId=${nav}&roomId=&word=&page=${pg}&pageSize=30&channelId=3&platform=1`) || {};
        const list = (data.list || []).filter(r => field(r, 'roomId') && field(r, 'title'))
            .map(r => ({ vod_id: field(r, 'roomId'), vod_name: field(r, 'title'), vod_pic: field(r, 'cover'), vod_remarks: field(r, 'navName') }));
        return { page: parseInt(pg, 10), pagecount: 71582788, limit: 30, total: 2147483647, list };
    },
    detail(id) {
        const data = room(`info?roomId=${id}&channelId=3&platform=1`);
        if (!data) return { list: [], msg: '暂无详情数据' };
        const episodes = [];
        if (field(data, 'pushUrl')) episodes.push('flv$' + b64(field(data, 'pushUrl')));
        if (field(data, 'pullUrl')) episodes.push('m3u8$' + b64(field(data, 'pullUrl')));
        if (!episodes.length) return { list: [], msg: '暂无播放数据' };
        return { list: [{
            vod_id: id, vod_name: field(data, 'title'), vod_pic: field(data, 'cover'), type_name: field(data, 'nickName'),
            vod_content: field(data, 'description') || field(data, 'notice'), vod_remarks: field(data, 'navName'), vod_play_from: '球通', vod_play_url: episodes.join('#')
        }] };
    },
    search() { return { list: [] }; },
    play(flag, id) {
        let url = id;
        try { const decoded = Buffer.from(id, 'base64').toString('utf8'); if (/^https?:\/\//.test(decoded)) url = decoded; } catch { /* plain */ }
        const result = { parse: 0, url, header: HEADERS };
        if (url.includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
