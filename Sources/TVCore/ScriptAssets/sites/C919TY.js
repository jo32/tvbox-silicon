// 919体育 (csp_C919TY): live match lists; each match has the anchor's stream plus other anchors' screens.
const API = 'https://01cs01.fusk39cd.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const get = path => { try { return JSON.parse(globalThis.req(API + path, { headers: { 'User-Agent': UA } }).content || '{}'); } catch { return {}; } };
const field = (o, k) => o && k in o && String(o[k]) !== 'null' ? String(o[k]) : '';
const cover = o => field(o, 'cover') || field(o, 'home_logo') || field(o, 'away_logo') || field(o, 'face');
function status(o) {
    const home = Number(o.home_score) || 0, away = Number(o.away_score) || 0;
    const label = field(o, 'on_time') || field(o, 'league_name_zh');
    return home > 0 || away > 0 ? `${label} 比分${home}-${away}` : label;
}

export default {
    home() { return { class: [['1', '全部'], ['2', '足球'], ['3', '篮球']].map(([type_id, type_name]) => ({ type_id, type_name })), list: [] }; },
    category(tid, pg) {
        const page = parseInt(pg, 10) || 1;
        const data = get('/api/web/live_lists/' + tid);
        if (data.code !== 200) return { page, pagecount: 1, limit: 20, total: 0, list: [] };
        const list = ((data.data || {}).data || []).filter(m => m && 'tournament_id' in m && field(m, 'type') && field(m, 'tournament_id') && field(m, 'member_id'))
            .map(m => ({
                vod_id: `${field(m, 'type')}|${field(m, 'tournament_id')}|${field(m, 'member_id')}`, vod_name: `${field(m, 'home_team_zh')} VS ${field(m, 'away_team_zh')}`,
                vod_pic: cover(m), vod_remarks: [field(m, 'league_name_zh'), status(m)].filter(Boolean).join(' ').trim()
            }));
        return { page, pagecount: 1, limit: 20, total: list.length, list };
    },
    detail(id) {
        const parts = String(id).split('|');
        if (parts.length !== 3) return { list: [] };
        const data = get(`/api/web/live_lists/${parts[0]}/detail/${parts[1]}?member_id=${parts[2]}`);
        const detail = data.code === 200 && data.data && data.data.detail;
        if (!detail) return { list: [] };
        const froms = [], urls = [];
        const add = (name, url, stream) => {
            const items = [];
            if (url) items.push('线路一$' + url);
            if (stream) items.push('线路二$' + stream);
            if (items.length) { froms.push(name || '播放'); urls.push(items.join('#')); }
        };
        add(field(detail, 'nickname'), field(detail, 'url'), field(detail, 'stream'));
        for (const more of data.data.more || []) if (more) add(field(more, 'username'), field(more, 'screen_url'), field(more, 'screen_url_m3u8'));
        if (!urls.length) return { list: [], msg: '暂无播放数据' };
        return { list: [{
            vod_id: id, vod_name: `${field(detail, 'home_team_zh')} VS ${field(detail, 'away_team_zh')}`, vod_pic: cover(detail), vod_remarks: status(detail),
            vod_content: field(detail, 'room_notice_new') || field(detail, 'room_notice'), vod_play_from: froms.join('$$$'), vod_play_url: urls.join('$$$')
        }] };
    },
    search() { return { list: [] }; },
    play(flag, id) {
        const result = { parse: 0, url: id, header: { 'User-Agent': UA } };
        if (id.includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
