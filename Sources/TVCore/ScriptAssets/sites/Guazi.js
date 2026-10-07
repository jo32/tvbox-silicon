// 瓜子影视 (csp_Guazi): an app API. Requests are JSON, AES-CBC encrypted, with the AES key and IV
// RSA-encrypted for the server and an MD5 signature. Responses carry an RSA-wrapped AES key.
import { aesEncrypt, aesDecrypt, rsaEncrypt, rsaDecrypt, md5, randomHex, http, formBody, store, resolutionRank, text } from './_lite.js';

const HOSTS = ['https://apinew.uozvr.com', 'https://api.w32z7vtd.com', 'https://api.6a7nnf7.com', 'https://api.umygrx3.com', 'https://api.rmedphk.com'];
const AES_KEY = 'OITxa5OqAYjhswxx';
const AES_IV = 'rCMNwZASNBKZ8mXV';
const SERVER_KEY = 'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDUM5+/y8sPsWkd1/RQS64X259EUwxFXFE5HlA65MqrxnPs0JqoSRojSDy5QhwvROlaD6TwRQHKMY2OAZ6SnQeUJsChTEFIR9qUkwrs3/MVUMxjsv6JS6Oe/juclyJGTgVmDhB55EafXsD0SQYVj/QXXsxR6ewR5E2kL52yAAD4yQIDAQAB';
const CLIENT_KEY = 'MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGAe6hKrWLi1zQmjTT1ozbE4QdFeJGNxubxld6GrFGximxfMsMB6BpJhpcTouAqywAFppiKetUBBbXwYsYU1wNr648XVmPmCMCy4rY8vdliFnbMUj086DU6Z+/oXBdWU3/b1G0DN3E9wULRSwcKZT3wj/cCI1vsCm3gj2R5SqkA9Y0CAwEAAQKBgAJH+4CxV0/zBVcLiBCHvSANm0l7HetybTh/j2p0Y1sTXro4ALwAaCTUeqdBjWiLSo9lNwDHFyq8zX90+gNxa7c5EqcWV9FmlVXr8VhfBzcZo1nXeNdXFT7tQ2yah/odtdcx+vRMSGJd1t/5k5bDd9wAvYdIDblMAg+wiKKZ5KcdAkEA1cCakEN4NexkF5tHPRrR6XOY/XHfkqXxEhMqmNbB9U34saTJnLWIHC8IXys6Qmzz30TtzCjuOqKRRy+FMM4TdwJBAJQZFPjsGC+RqcG5UvVMiMPhnwe/bXEehShK86yJK/g/UiKrO87h3aEu5gcJqBygTq3BBBoH2md3pr/W+hUMWBsCQQChfhTIrdDinKi6lRxrdBnn0Ohjg2cwuqK5zzU9p/N+S9x7Ck8wUI53DKm8jUJE8WAG7WLj/oCOWEh+ic6NIwTdAkEAj0X8nhx6AXsgCYRql1klbqtVmL8+95KZK7PnLWG/IfjQUy3pPGoSaZ7fdquG8bq8oyf5+dzjE/oTXcByS+6XRQJAP/5ciy1bL3NhUhsaOVy55MHXnPjdcTX0FaLi+ybXZIfIQ2P4rb19mVq1feMbCXhz+L1rG8oat5lYKfpe8k83ZA==';
const SALT = '*&zvdvdvddbfikkkumtmdwqppp?|4Y!s!2br';
const OLD_KEY = 'aLFBMWpxBrIDAD1Si/KVvm41';
const PLAY_HEADERS = { 'User-Agent': 'Lavf/57.83.100', Referer: 'http://WJiZxLXA2.com/' };
const PIC_SUFFIX = '@User-Agent=Dalvik/2.1.0';
const SUBTYPES = { 1: '5', 2: '12', 3: '30', 4: '22', 64: '' };

const saved = store('guazi');
let base = '';
let auth = {};
let refreshed = false;

function pickHost() {
    for (const candidate of HOSTS) {
        try {
            const response = globalThis.req(candidate, { method: 'HEAD', timeout: 3000, headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' } });
            if (response.code >= 200 && response.code < 300) return candidate;
        } catch { /* next */ }
    }
    return HOSTS[0];
}

function call(path, params, attempt = 0) {
    const authPath = path.startsWith('/App/Authentication/');
    if (!authPath) ensureToken();
    const payload = { ...params };
    if ('token' in payload) payload.token = auth.token;
    if ('token_id' in payload) payload.token_id = auth.tokenId;
    const requestKey = aesEncrypt(JSON.stringify(payload), AES_KEY, AES_IV, { output: 'hex' }).toUpperCase();
    const time = String(Math.floor(Date.now() / 1000));
    const keys = rsaEncrypt(JSON.stringify({ iv: AES_IV, key: AES_KEY }), SERVER_KEY);
    const signature = md5(`token_id=,token=${auth.token},phone_type=1,request_key=${requestKey},app_id=1,time=${time},keys=${keys}${SALT}`).toUpperCase();
    const body = formBody({ token: auth.token, token_id: '', phone_type: '1', time, phone_model: 'xiaomi-25031', keys, request_key: requestKey, signature, app_id: '1', ad_version: '1' });
    const response = http(base + path, {
        method: 'POST', body, headers: {
            'User-Agent': 'Lavf/57.83.100', code: 'GZ0369', deviceId: auth.deviceId, lang: 'zh_cn', 'Cache-Control': 'no-cache',
            'Content-Type': 'application/x-www-form-urlencoded', Version: '2604028', PackageName: 'com.ae06aebdbb.y286327f5a.ofe849883320260517',
            Ver: '3.0.3.2', 'api-ver': '3.0.3.2'
        }
    });
    if (!response.content) throw new Error('瓜子: empty response');
    const answer = JSON.parse(response.content);
    if (answer.code != null && Number(answer.code) !== 200) {
        if (attempt >= 1 || authPath) throw new Error('瓜子 request failed: ' + response.content.slice(0, 200));
        refreshed = false;
        ensureToken();
        return call(path, params, attempt + 1);
    }
    const data = answer.data || {};
    const wrapped = JSON.parse(rsaDecrypt(data.keys, CLIENT_KEY));
    return JSON.parse(aesDecrypt(data.response_key, wrapped.key, wrapped.iv, { input: 'hex' }));
}

function save() { saved.setJSON('auth', auth); }

function accept(json) {
    if (!json.token) throw new Error('瓜子 token failed: ' + JSON.stringify(json).slice(0, 200));
    auth.token = json.token;
    if (json.app_user_id) auth.tokenId = String(json.app_user_id);
    save();
}

function ensureToken() {
    if (!base || (refreshed && auth.token)) return;
    if (!auth.token) {
        if (auth.registered) accept(call('/App/Authentication/Device/signIn', { new_key: auth.deviceKey, old_key: OLD_KEY }));
        else {
            accept(call('/App/Authentication/Device/signUp', { new_key: auth.deviceKey, old_key: OLD_KEY, phone_type: 1, code: '' }));
            auth.registered = true; save();
        }
    }
    try { accept(call('/App/Authentication/Authenticator/refresh', {})); }
    catch (error) {
        if (!auth.registered) throw error;
        accept(call('/App/Authentication/Device/signIn', { new_key: auth.deviceKey, old_key: OLD_KEY }));
    }
    refreshed = true;
}

function videos(json) {
    return (json.list || []).map(item => {
        let remarks = text(item.vod_scroe);
        if ('vod_continu' in item) {
            const current = text(item.vod_continu), total = text(item.d_total);
            remarks = current === '0' || total === '0' ? text(item.vod_year) : current === total ? `全${total}集` : `更新至${current}集`;
        }
        return { vod_id: text(item.vod_id), vod_name: text(item.vod_name), vod_pic: text(item.vod_pic) + PIC_SUFFIX, vod_remarks: remarks };
    });
}

export default {
    init() {
        base = pickHost();
        auth = saved.json('auth') || {};
        if (!auth.deviceId || !auth.deviceKey) {
            auth = { deviceId: String(864150060000000 + Math.floor(Math.random() * 10000)), deviceKey: randomHex(20).toUpperCase(), token: '', tokenId: '', registered: false };
            save();
        }
        auth.token ||= ''; auth.tokenId ||= '';
        refreshed = false;
        try { ensureToken(); } catch { /* retried on the first request */ }
    },
    home() {
        return { class: [['1', '电影'], ['2', '国产剧'], ['4', '动漫'], ['64', '短剧'], ['3', '综艺'], ['5', '海外剧']].map(([type_id, type_name]) => ({ type_id, type_name })) };
    },
    homeVod() {
        const rows = call('/App/IndexList/index', { pid: '1' }).list || [];
        return { list: rows.slice(1).flatMap(videos) };
    },
    category(tid, pg, filter, extend = {}) {
        const params = { tid, page: pg, pageSize: '30', area: extend.area || '0', year: extend.year || '0', sort: extend.sort || 'd_id', sub: extend.sub || '0' };
        return { list: videos(call('/App/IndexList/indexList', params)), page: Number(pg) };
    },
    detail(id) {
        const info = call('/App/IndexPlay/playInfo', { token_id: auth.tokenId, vod_id: id, mobile_time: String(Math.floor(Date.now() / 1000)), token: auth.token }).vodInfo || {};
        const sources = call('/App/Resource/Vurl/show', { vurl_cloud_id: '2', vod_d_id: id });
        const groups = new Map();
        const rows = Array.isArray(sources.list) ? sources.list : [];
        rows.forEach((row, index) => {
            const title = rows.length === 1 ? text(info.vod_name) : String(index + 1);
            for (const [quality, entry] of Object.entries(row.play || {})) {
                const param = entry && entry.param != null ? text(entry.param) : '';
                if (!param) continue;
                if (!groups.has(quality)) groups.set(quality, []);
                groups.get(quality).push(`${title}$${param}||${quality}`);
            }
        });
        const names = [...groups.keys()].sort((a, b) => resolutionRank(b) - resolutionRank(a));
        return { list: [{
            vod_id: id, vod_name: text(info.vod_name), vod_pic: text(info.vod_pic) + PIC_SUFFIX, vod_year: text(info.vod_year),
            vod_area: text(info.vod_area), vod_actor: text(info.vod_actor), vod_director: text(info.vod_director),
            vod_content: text(info.vod_use_content).replace(/　/g, '\n').trim(),
            vod_play_from: names.join('$$$'), vod_play_url: names.map(name => groups.get(name).join('#')).join('$$$')
        }] };
    },
    search(wd) {
        return { list: videos(call('/App/Index/findMoreVod', { keywords: wd, order_val: '1' })) };
    },
    play(flag, id) {
        const [query, quality] = id.split('||');
        const params = {};
        for (const pair of query.split('&')) {
            const [key, value] = pair.split('=');
            if (value !== undefined) params[key === 'vod_d_id' ? 'vod_id' : key] = value;
        }
        params.resolution = quality || flag;
        const answer = call('/App/Resource/VurlDetail/showOne', params);
        return { parse: 0, url: text(answer.url), header: PLAY_HEADERS };
    }
};
