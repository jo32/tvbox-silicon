// 瓜子体育 (csp_GuaziTY): a live-sports API whose `parameter` and `data` fields are AES-CBC (base64).
// ext: "https://..." or {"api"|"site": ..., "key": ..., "iv": ...}
import { aesEncrypt, aesDecrypt } from './_lite.js';

const PLAY_HEADERS = { 'User-Agent': 'Lavf/57.83.100', Referer: 'http://WJiZxLXA2.com/' };
const QUERIES = {
    hot: '{"frame":"0","hot":"1","tag":"0","type":"0"}', nba: '{"frame":"0","hot":"0","tag":"37","type":"0"}',
    football: '{"frame":"0","hot":"0","tag":"0","type":"1"}', basketball: '{"frame":"0","hot":"0","tag":"0","type":"2"}'
};

let api = 'https://api.46d5umpk.com';
let key = 'KANGEQIU@8868!~.', iv = '0200010900030207';

function call(path, json) {
    const form = 'parameter=' + encodeURIComponent(aesEncrypt(json, key, iv));
    const headers = { 'User-Agent': 'okhttp/3.12.0', 'content-type': 'application/x-www-form-urlencoded', 'user-platform': 'null', 'client-version': '3.0.1.1', 'client-channel': '', token: '' };
    const data = String(JSON.parse(globalThis.req(`${api}/gz/live/${path}?parameter=key`, { method: 'POST', body: form, headers }).content || '{}').data || '');
    try { return aesDecrypt(data.replace(/\\/g, ''), key, iv); } catch { return data; }
}

const field = (o, k) => o && k in o && String(o[k]) !== 'null' ? String(o[k]) : '';
const side = (o, k) => (o && o[k]) || {};
const logo = o => field(o, 'event_logo') || field(side(o, 'home'), 'logo') || field(side(o, 'visiting'), 'logo');
function status(text, o) {
    const home = Number(side(o, 'home').score) || 0, away = Number(side(o, 'visiting').score) || 0;
    return home > 0 || away > 0 ? `${text} 比分${home}-${away}` : text;
}
const pad = n => String(n).padStart(2, '0');
const when = ms => { const d = new Date(ms); return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };

export default {
    init(ext) {
        const value = String(ext || '').trim();
        if (!value) return;
        if (value.startsWith('http')) { api = value.replace(/\/+$/, ''); return; }
        try {
            const config = JSON.parse(value);
            const address = String(config.api || config.site || '');
            if (address) api = address.replace(/\/+$/, '');
            if (config.key) key = String(config.key);
            if (config.iv) iv = String(config.iv);
        } catch { /* defaults */ }
    },
    home() { return { class: [['hot', '热门'], ['nba', 'NBA'], ['football', '足球'], ['basketball', '篮球']].map(([type_id, type_name]) => ({ type_id, type_name })), list: [] }; },
    category(tid, pg) {
        if (String(pg) !== '1') return { list: [] };
        let matches = [];
        try { matches = JSON.parse(call('sports', QUERIES[tid] || QUERIES.hot)); } catch { matches = []; }
        const since = Date.now() - 86400000;
        const list = matches.filter(m => m && Number(m.match_time) * 1000 >= since && (Number(m.m_status) || 0) < 2).map(m => {
            const name = `${field(side(m, 'home'), 'name')} vs ${field(side(m, 'visiting'), 'name')}`;
            return { vod_id: field(m, 'mid'), vod_name: name, vod_pic: logo(m), vod_remarks: `${field(m, 'event_name')} ${when(Number(m.match_time) * 1000)} ${status(field(m, 'match_status_info'), m)}` };
        }).filter(v => v.vod_id && v.vod_name.trim());
        return { page: 1, pagecount: 1, limit: list.length, total: list.length, list };
    },
    detail(id) {
        let data = {};
        try { data = JSON.parse(call('detail', JSON.stringify({ mid: id }))); } catch { data = {}; }
        const lines = (data.live_line || []).filter(l => l && field(l, 'm3u8')).map(l => `${field(l, 'name') || '播放'}$${field(l, 'm3u8')}`);
        if (!lines.length) return { list: [], msg: '暂无播放数据' };
        const name = `${field(side(data, 'home'), 'name')} vs ${field(side(data, 'visiting'), 'name')}`;
        const remarks = status(field(data, 'match_status_info'), data);
        return { list: [{ vod_id: id, vod_name: name, vod_pic: logo(data), vod_remarks: remarks, vod_content: remarks, vod_play_from: '瓜子', vod_play_url: lines.join('#') }] };
    },
    search() { return { list: [] }; },
    play(flag, id) {
        const result = { parse: 0, url: id, header: PLAY_HEADERS };
        if (id.includes('.m3u8')) result.format = 'application/x-mpegURL';
        return result;
    }
};
