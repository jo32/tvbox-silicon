// 荐片 (fty csp_JPJGuard): the jp3 API of Jianpian.js under the fan123.<domain> host.
import site from './Jianpian.js';

export default { ...site, init(ext) { return site.init(JSON.stringify({ filters: String(ext || ''), prefix: 'fan123.' })); } };
