#!/usr/bin/env python3
"""Exercise the embedded Node host against local HTTP/HTTPS sites (no external network)."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request

root = Path(__file__).resolve().parents[1]
node = os.environ.get('NODE_BIN') or shutil.which('node') or str(root / 'build/ScriptHost/node')
with tempfile.TemporaryDirectory(prefix='yingxia-node-test-') as folder:
    job = Path(folder)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=localhost', '-keyout', str(job / 'key.pem'), '-out', str(job / 'cert.pem')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (job / 'relisten').touch()
    # Model nodejs-mobile 18's defaults even when the check runs with desktop Node 19+.
    (job / 'runner.mjs').write_text('''
import http from 'node:http';
import https from 'node:https';
http.globalAgent.keepAlive = false;
https.globalAgent.keepAlive = false;
process.argv = ['node', process.argv[2], ...process.argv.slice(3)];
await import(process.argv[1]);
''')
    # A source that needs two requests to one upstream. A new TCP/TLS connection for its second
    # request is rejected, as sites that drop rapid repeat handshakes do. Only the fixture's own
    # self-signed certificate opts out of verification; the host must retain normal verification.
    (job / 'index.js').write_text('''
const http = require('http'), https = require('https'), fs = require('fs');
const path = require('path');
const servers = {};
exports.start = async () => {
  for (const [name, mod] of [['http', http], ['https', https]]) {
    const sockets = new Set();
    const handler = (req, res) => {
      sockets.add(req.socket);
      res.writeHead(sockets.size === 1 ? 200 : 503);
      res.end('site response');
    };
    const server = name === 'https' ? https.createServer({
      key: fs.readFileSync(path.join(__dirname, 'key.pem')),
      cert: fs.readFileSync(path.join(__dirname, 'cert.pem')),
    }, handler) : http.createServer(handler);
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    servers[name] = server;
  }
  const server = globalThis.catServerFactory(async (req, res) => {
    for await (const ignored of req) {}
    if (req.url.endsWith('/init')) { res.end('{}'); return; }
    const name = req.url.includes('/https/') ? 'https' : 'http';
    const mod = name === 'https' ? https : http;
    const get = () => new Promise((resolve, reject) => {
      const r = mod.get({host: '127.0.0.1', port: servers[name].address().port,
                        rejectUnauthorized: false}, response => {
        response.resume(); response.on('end', () => resolve(response.statusCode));
      }); r.on('error', reject);
    });
    const first = await get();
    await new Promise(resolve => setImmediate(resolve));
    const second = await get();
    const ok = first === 200 && second === 200;
    res.writeHead(ok ? 200 : 500, {'content-type': 'application/json'});
    res.end(JSON.stringify(ok ? {list:[{vod_id:name, vod_name:'Found'}]} : {message:'The site rejected a new connection'}));
  });
  server.listen();
};
''')
    control = job / 'control.json'
    with (job / 'host.log').open('w') as log:
        process = subprocess.Popen([node, str(job / 'runner.mjs'), str(root / 'Runtime/NodeHost/main.mjs'),
                                    str(control), str(job / 'relisten')], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while not control.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError((job / 'host.log').read_text())
                time.sleep(.02)
            config = json.loads(control.read_text())
            for scheme in ('http', 'https'):
                data = dict(bundle=str(job / 'index.js'), api='http://127.0.0.1:1/index.js',
                            profile=str(job / 'profile'), params={'catPawOpen':f'/spider/{scheme}/3', 'wd':'test'})
                req = urllib.request.Request(f'http://127.0.0.1:{config["port"]}/call',
                                             data=json.dumps(data).encode(),
                                             headers={'x-yingxia-token': config['token'], 'content-type':'application/json'})
                envelope = json.load(urllib.request.urlopen(req, timeout=10))
                assert 'error' not in envelope, envelope
                result = json.loads(envelope['result'])
                assert result['list'] == [{'vod_id':scheme, 'vod_name':'Found'}], result
        finally:
            process.terminate()
            process.wait(timeout=5)
print('Embedded Node host checks passed: HTTP and HTTPS source requests reuse upstream connections.')
