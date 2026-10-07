// 贝乐虎 (csp_BeiLeHu): the ubestkid video API; ids carry url@@title@@image so detail needs no request.
const API = 'https://vd.ubestkid.com/api/v1/bv/video';
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1';
const CLASSES = [['56', '儿歌'], ['63', '故事'], ['62', '古诗'], ['61', '英语'], ['64', '认知'], ['65', '习惯']];

function videos(page, category, limit = Infinity) {
    const body = JSON.stringify({ age: 1, appver: '6.1.9', egvip_status: 0, svip_status: 0, vps: 60, subcateId: parseInt(category, 10), p: page });
    try {
        const data = JSON.parse(globalThis.req(API, { method: 'POST', body, headers: { 'User-Agent': UA, 'Content-Type': 'application/json' } }).content);
        return ((data.result || {}).items || []).slice(0, limit).map(v => ({
            vod_id: `${v.url}@@${v.title}@@${v.image}`, vod_name: String(v.title || ''), vod_pic: String(v.image || ''), vod_remarks: String(v.viewcount ?? '')
        }));
    } catch { return []; }
}

export default {
    home() { return { class: CLASSES.map(([type_id, type_name]) => ({ type_id, type_name })), list: videos(1, '56', 20) }; },
    category(tid, pg) { return { list: videos(parseInt(pg, 10) || 1, tid) }; },
    detail(id) {
        const [url = '', title = '', image = ''] = String(id).split('@@');
        return { list: [{ vod_id: id, vod_name: title, vod_pic: image, type_name: '少儿', vod_content: title, vod_play_from: '贝乐虎', vod_play_url: '播放$' + url }] };
    },
    search() { return { list: [] }; },
    play(flag, id) { return { parse: 0, url: String(id).split('@@')[0], header: { 'User-Agent': UA } }; }
};
