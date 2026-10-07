// 超全体育 (csp_Sir88): 88直播 live rooms. Clarity lines are signed play/url requests (md5 of the sorted
// params plus a salt); the reply is JSON or AES-CBC base64 JSON carrying data.play_url.
// ext: optional API base, default https://apc.r8z1l0r3j9d8z7r8y1.vip/
import { md5, aesDecrypt, formBody } from './_lite.js';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
const PLAY_API = 'https://openim-php-api.x3t9p9f5h0l3.cc/v230/play/url';
const SALT = 'yKBm0pKLdVcGbnu4XGon13TsyBdEsjj3WVAzszpoqjn3BNmovLgzvcRTxD1Wey7QQ10kcov0b8e9oBi7jAUR';
const KEY = 'j3Qpq3BWs6qUCctm', IV = 'b2mdEEYbW1qprFsg';
const HIDDEN = new Set(['88', '83', '74', '81', '80']);
const ADS = ['百家', '赌', '彩票', '棋牌', '一起', '电子'];

let api = 'https://apc.r8z1l0r3j9d8z7r8y1.vip/';

function base(value) {
    let text = String(value).trim();
    const colon = text.indexOf(':');
    const scheme = colon > 0 ? text.slice(0, colon) : 'https';
    if (colon > 0) text = text.slice(Math.min(colon + 3, text.length));
    return `${scheme}://${text.replace(/\/+$/, '')}/`;
}
const get = path => { try { return JSON.parse(globalThis.req(api + path, { headers: { 'User-Agent': UA } }).content || '{}'); } catch { return {}; } };
const str = (o, k, d = '') => o && o[k] != null && String(o[k]) !== 'null' ? String(o[k]) : d;
const lineId = (room, sport, match, code) => `SIR88@@@${room}@@@${sport}@@@${match}@@@${code}`;

function rooms(data) {
    const list = (((data.data || [])[0] || {}).rooms || []).filter(Boolean);
    const isAd = r => ADS.some(word => str(r, 'room_title').includes(word));
    return [...list.filter(r => !isAd(r)), ...list.filter(isAd)];
}
const room = (r, remarks) => ({
    vod_id: `${str(r, 'chatroom_id', '0')}@@@${str(r, 'sport_id', '0')}@@@${str(r, 'match_id', '0')}`,
    vod_name: str(r, 'room_title'), vod_pic: str(r, 'match_screenshot_url') || str(r, 'screenshot_url'), vod_remarks: remarks
});

function matchTime(seconds) {
    if (!(seconds > 0)) return '';
    const shanghai = ms => new Date(ms + 8 * 3600 * 1000);
    const when = shanghai(seconds * 1000), now = shanghai(Date.now()), tomorrow = shanghai(Date.now() + 86400 * 1000);
    const pad = n => String(n).padStart(2, '0');
    const sameDay = (a, b) => a.getUTCFullYear() === b.getUTCFullYear() && a.getUTCMonth() === b.getUTCMonth() && a.getUTCDate() === b.getUTCDate();
    const clock = `${pad(when.getUTCHours())}:${pad(when.getUTCMinutes())}`;
    if (sameDay(when, now)) return '今日-' + clock;
    if (sameDay(when, tomorrow)) return '明日-' + clock;
    return `${pad(when.getUTCMonth() + 1)}-${pad(when.getUTCDate())} ${clock}`;
}

export default {
    init(ext) {
        api = base('https://apc.r8z1l0r3j9d8z7r8y1.vip/');
        if (ext && String(ext).trim()) api = base(ext);
    },
    home() {
        const classes = (get('v14/channel/list').data || []).filter(c => c && !HIDDEN.has(str(c, 'channel_id')))
            .map(c => ({ type_id: str(c, 'channel_id'), type_name: str(c, 'channel_name') === '推荐' ? '直播中' : str(c, 'channel_name') }));
        return { class: classes, list: rooms(get('v14/live/getlist?channel_id=68&page=0')).map(r => room(r, '热播')) };
    },
    category(tid, pg) {
        const page = parseInt(pg, 10) || 1;
        const list = rooms(get(`v14/live/getlist?channel_id=${tid}&page=${page - 1}`)).map(r => room(r, '直播中'));
        if (list.length || page > 1) return { page, pagecount: page + 1, limit: list.length, total: list.length, list };
        const matches = ((get('v14/live/schedule?channel_id=' + tid).data || {}).match_list || []).filter(Boolean).map(m => ({
            vod_id: `${str(m, 'chatroom_id', '0')}@@@${str(m, 'sport_id', '0')}@@@${str(m, 'match_id', '0')}`,
            vod_name: `${str(m, 'alias_name')} ${str(m, 'home_name')} VS ${str(m, 'away_name')}`,
            vod_pic: str(m, 'home_logo'), vod_remarks: matchTime(Number(m.match_time) || 0)
        }));
        return { page: 1, pagecount: 1, limit: matches.length, total: matches.length, list: matches };
    },
    detail(id) {
        const [roomId, sport = '0', match = '0'] = String(id).split('@@@');
        let path = `v1/room?room_id=${roomId}&sport_id=${sport}`;
        if (match !== '0') path += '&match_id=' + match;
        const data = get(path).data;
        if (!data) return { list: [], msg: '直播间不存在' };
        const lines = [], seen = new Set();
        const addUrl = (name, url) => { if (url && !seen.has(url)) { seen.add(url); lines.push(`${name || '播放'}$${url}`); } };
        const addCode = c => {
            if (!c || Number(c.login_status) === 1) return;
            const code = str(c, 'code_id') || str(c, 'code');
            if (!code) return;
            const target = lineId(roomId, sport, match, code);
            if (seen.has(target)) return;
            seen.add(target);
            lines.push(`${str(c, 'name') || str(c, 'title') || code}$${target}`);
        };
        for (const flow of data.play_flow || []) if (flow) str(flow, 'play_url') ? addUrl(str(flow, 'name'), str(flow, 'play_url')) : addCode(flow);
        addUrl('RTMP', str(data, 'pull_rtmp_url'));
        addUrl('FLV', str(data, 'pull_flv_url'));
        for (const c of data.play_clarity || data.clarity || []) addCode(c);
        if (!lines.length) addUrl('标清', lineId(roomId, sport, match, 'bqzm'));
        return { list: [{
            vod_id: String(id), vod_name: str(data, 'room_title'), vod_pic: str(data, 'screenshot_url') || str(data.match_info, 'screenshot_url'),
            vod_content: '请勿相信视频中任何广告', vod_play_from: '直播', vod_play_url: lines.join('#')
        }] };
    },
    search() { return { list: [] }; },
    play(flag, id) {
        let url = String(id);
        const parts = url.split('@@@');
        if (url.startsWith('SIR88@@@') && parts.length >= 5) {
            const [, roomId, sport, match, code] = parts;
            const params = { room_id: roomId, code_id: code, time: String(Math.floor(Date.now() / 1000)) };
            if (match !== '0') params.match_id = match;
            if (sport !== '0') params.sport_id = sport;
            params.signature = md5(Object.keys(params).sort().map(k => k + params[k]).join('') + SALT);
            try {
                let body = String(globalThis.req(PLAY_API, { method: 'POST', body: formBody(params), headers: {
                    'User-Agent': UA, Accept: 'application/json, text/javascript, */*; q=0.01', 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8',
                    version: '1.8.4', device: '3', platform: '88zb', device2: '3', imei: '9d5f4a17158f4b248771ea0952f5f549', 'dun-imei': '', 'api-version': '1.8.4'
                } }).content || '').trim();
                if (body.startsWith('"') && body.endsWith('"')) body = JSON.parse(body);
                if (!body.startsWith('{')) body = aesDecrypt(body, KEY, IV);
                const playUrl = str(JSON.parse(body).data, 'play_url');
                if (playUrl) url = playUrl;
            } catch {}
        }
        if (url.startsWith('SIR88@@@')) return { parse: 0, url: '' };
        const result = { parse: 0, url, header: { 'User-Agent': UA, Accept: '*/*', Connection: 'Keep-Alive', Referer: api } };
        if (url.includes('.m3u8')) result.format = 'application/x-mpegURL';
        else if (url.includes('.flv')) result.format = 'video/x-flv';
        return result;
    }
};
