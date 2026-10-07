// 多多回放 (fty csp_DoubaoGuard): doubaozhibo.com live schedule and match replays. Ids keep the JAR's forms,
// "live###<schedule id>" and "replay###<playback id>". Live lines are play pages whose HTML carries the m3u8.
const HOST = 'https://www.doubaozhibo.com';
const HEADERS = { Accept: 'application/json', 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36', 'Accept-Language': 'zh-CN' };
const REPLAY_PIC = 'https://img07.sogoucdn.com/v2/thumb/retype_exclude_gif/ext/auto/q/95/crop/xy/ai/t/0/?appid=122&url=https://s1.imagehub.cc/images/2026/06/11/822f293c60093b512da3def049555e77.md.png';
const CLASSES = [['live_tab', '📡 赛事直播'], ['replay_all', '🎬 全部回放'], ['replay_football', '⚽ 足球回放'], ['replay_basketball', '🏀 篮球回放']];

const getJSON = url => { try { return JSON.parse(globalThis.req(url, { headers: HEADERS, timeout: 15000 }).content || '{}'); } catch { return {}; } };
const pad = n => String(n).padStart(2, '0');
function shanghai(iso) {
    const time = Date.parse(iso || '');
    if (isNaN(time)) return String(iso || '');
    const d = new Date(time + 8 * 3600 * 1000);
    return `${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
}

let schedule = null, scheduleAt = 0;
const replays = new Map();
function matches() {
    if (schedule && Date.now() - scheduleAt < 60000) return schedule;
    const days = ((getJSON(HOST + '/api/v1/schedules/public/local').data || {}).days) || [];
    schedule = days.flatMap(day => [...(day.live || []), ...(day.playback || [])]).filter(m => m && m.id != null);
    scheduleAt = Date.now();
    return schedule;
}
const liveCard = m => ({
    vod_id: `live###${m.id}`, vod_name: `${m.teamA || ''} vs ${m.teamB || ''}`, vod_pic: String(m.teamAImage || ''),
    vod_remarks: Number(m.status) === 1 ? `直播中 | ${m.league || ''}` : `⏰ ${shanghai(m.matchTime)} | ${m.league || ''}`
});
function replayPage(page, type) {
    const data = getJSON(`${HOST}/api/v1/playbacks?page=${page}&pageSize=20&dataType=${type}`).data || {};
    const list = (data.list || []).filter(x => x && x.schedule && x.playback).map(({ schedule: s, playback: p }) => {
        replays.set(String(p.id), { s, p });
        return { vod_id: `replay###${p.id}`, vod_name: `${s.teamA || ''} ${Number(s.teamAscore) || 0}-${Number(s.teamBscore) || 0} ${s.teamB || ''}`, vod_pic: REPLAY_PIC, vod_remarks: `🟡 ${shanghai(s.matchTime)} | ${s.league || ''}` };
    });
    const size = Number(data.pageSize) || 20, total = Number(data.total) || 0;
    return { page: Number(data.page) || page, pagecount: Math.max(1, Math.ceil(total / size)), limit: size, total, list };
}

export default {
    // Home leads with matches that are live now, then the latest replays (upcoming matches have no stream yet).
    home() {
        const live = matches().filter(m => Number(m.status) === 1).map(liveCard);
        let replays = [];
        try { replays = replayPage(1, 'all').list; } catch {}
        return { class: CLASSES.map(([type_id, type_name]) => ({ type_id, type_name })), list: [...live, ...replays] };
    },
    category(tid, pg) {
        const page = Math.max(1, parseInt(pg, 10) || 1);
        if (String(tid).startsWith('live')) { const list = matches().map(liveCard); return { page: 1, pagecount: 1, limit: list.length, total: list.length, list }; }
        const type = tid === 'replay_football' ? 'football' : tid === 'replay_basketball' ? 'basketball' : 'all';
        return replayPage(page, type);
    },
    detail(id) {
        const [kind, key] = String(id).split('###');
        if (kind === 'live') {
            const m = matches().find(x => String(x.id) === key);
            if (!m) return { list: [] };
            const lines = (m.signals || []).filter(s => s && s.playId).map(s => `${s.name || s.label}$${s.playId}`);
            return { list: [{ vod_id: id, vod_name: `${m.teamA || ''} VS ${m.teamB || ''}`, vod_pic: String(m.teamAImage || ''), type_name: String(m.league || ''),
                vod_remarks: `${m.league || ''} | ${shanghai(m.matchTime)} | ${Number(m.status) === 1 ? '直播中' : '未开始'}`, vod_content: '请勿相信视频中广告',
                vod_play_from: '直播线路', vod_play_url: lines.join('#') }] };
        }
        for (let page = 1; !replays.has(key) && page <= 3; page++) replayPage(page, 'all');
        const found = replays.get(key);
        if (!found) return { list: [] };
        const { s, p } = found;
        const lines = (p.lines || []).filter(l => l && l.proxyUrl).map(l => `${l.title || '回放'}$${HOST}${l.proxyUrl}`);
        return { list: [{ vod_id: id, vod_name: String(p.title || `${s.teamA} vs ${s.teamB}`), vod_pic: REPLAY_PIC, type_name: String(s.league || ''),
            vod_remarks: `${s.league || ''} | 回放`, vod_play_from: '回放', vod_play_url: lines.join('#') }] };
    },
    search() { return { list: [] }; },
    play(flag, id) {
        const target = String(id);
        if (target.startsWith('http')) return { parse: 0, url: target, header: HEADERS };
        const page = `${HOST}/play/${target}`;
        const html = String(globalThis.req(page, { headers: HEADERS, timeout: 15000 }).content || '').replace(/\\u002F/g, '/');
        const found = (html.match(/(https?:\/\/[\w.\-/:?=&]+\.m3u8[^,"\s]*)/) || [])[1];
        return found ? { parse: 0, url: found.replace(/[,"]+$/, ''), header: HEADERS } : { parse: 1, url: page, header: HEADERS };
    }
};
