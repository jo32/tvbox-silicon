#!/usr/bin/env python3
"""Exercise the bundled script host protocol without external network access."""
import json
import pathlib
import subprocess
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
host = root / 'build/ScriptHost'
with tempfile.TemporaryDirectory() as folder:
    job = pathlib.Path(folder)
    source = job / 'fixture.js'
    source.write_text('''
import {load} from 'lib/cheerio.min.js';
let selected = '';
export default {
  init() { local.set('test', 'runs', Number(local.get('test', 'runs') || 0) + 1); },
  home() { return {class: [{type_id: String(local.get('test', 'runs')), type_name: load('<b>title</b>')('b').text()}], list: [{vod_id: 'fallback'}]}; },
  homeVod() { return Number(local.get('test', 'runs')) === 1 ? JSON.stringify({list: [{vod_id: 'recommended', vod_name: 'Recommendation'}]}) : ''; },
  category(tid, pg, filter, extend) { return {list: [{vod_id: tid + '-' + pg, vod_name: JSON.stringify(extend)}]}; },
  detail(id) { selected = id; return {list: [{vod_id: id}]}; },
  play() { return {url: 'https://example.com/' + selected + '.mp4', parse: 0}; },
  search() { return {list: pdfa('<div><a href="/one">One</a><a href="/two">Two</a></div>', 'div&&a').map(html => ({vod_id: pd(html, 'a&&href', 'https://example.com'), vod_name: pdfh(html, 'a&&Text')}))}; }
};
''')
    request = job / 'request.json'
    request.write_text(json.dumps(dict(script=str(source), cache=str(job), api='https://fixture.example/spider.js', key='fixture')))
    def wait(file):
        until = time.monotonic() + 10
        while time.monotonic() < until:
            if file.exists(): return json.loads(file.read_text())
            time.sleep(.02)
        raise AssertionError('Host timed out: ' + str(file))
    for run in (1, 2):
        (job / 'ready.json').unlink(missing_ok=True)
        with open(job / 'log', 'w') as log:
            process = subprocess.Popen([str(host / 'node'), '--no-warnings', '--experimental-vm-modules', str(host / 'host.mjs'), '--serve', str(request)], stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
            try:
                assert wait(job / 'ready.json') == {'ready': True}
                counter = 0
                def call(params):
                    global counter
                    counter += 1
                    ident = f'{run}-{counter}'
                    process.stdin.write(json.dumps(dict(id=ident, params=params)) + '\n'); process.stdin.flush()
                    result = wait(job / 'responses' / (ident + '.json'))
                    assert 'error' not in result, result
                    return json.loads(result['result'])
                home = call({})
                assert home['class'][0] == {'type_id': str(run), 'type_name': 'title'}
                assert home['list'][0] == ({'vod_id': 'recommended', 'vod_name': 'Recommendation'} if run == 1 else {'vod_id': 'fallback'})
                assert call({'t': 'movie', 'pg': '2', 'filters': json.dumps({'area': '美国'})})['list'] == [{'vod_id': 'movie-2', 'vod_name': '{"area":"美国"}'}]
                assert call({'t': 'movie', 'pg': '1'})['list'] == [{'vod_id': 'movie-1', 'vod_name': '{}'}]
                call({'ids': 'chosen'})
                assert call({'play': 'opaque'})['url'] == 'https://example.com/chosen.mp4'
                assert call({'wd': 'test'})['list'] == [{'vod_id':'https://example.com/one', 'vod_name':'One'}, {'vod_id':'https://example.com/two', 'vod_name':'Two'}]
                process.stdin.close()
                assert process.wait(timeout=5) == 0
            finally:
                if process.poll() is None: process.kill(); process.wait()

# A CatPawOpen bundle (猫源): a search that finds nothing may answer HTTP 404, which is no results rather than a failure.
with tempfile.TemporaryDirectory() as folder:
    job = pathlib.Path(folder)
    bundle = job / 'index.js'
    bundle.write_text("""
exports.start = async () => {
  const server = globalThis.catServerFactory((req, res) => {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      const reply = (status, value) => { res.writeHead(status, {'content-type': 'application/json'}); res.end(JSON.stringify(value)); };
      // A site without an init route (#446) answers it 404 and serves the rest.
      if (req.url === '/spider/noinit/3/init') return reply(404, {error: '站点或接口不存在: noinit/init'});
      if (req.url === '/spider/noinit/3/home') return reply(200, {class: [{type_id: '1', type_name: 'Films'}], list: []});
      if (req.url.endsWith('/init')) return reply(200, {});
      if (req.url === '/spider/site/3/home') return reply(500, {message: 'home broke'});
      // A source whose search returns nothing answers 200 with an empty body.
      if (req.url === '/spider/blank/3/search') { res.writeHead(200); return res.end(); }
      // A site connection the far end dropped fails at once ("socket hang up"); the next try works.
      if (req.url === '/spider/stale/3/search') return (globalThis.stale = (globalThis.stale || 0) + 1) === 1
        ? reply(500, {message: 'socket hang up'}) : reply(200, {list: [{vod_id: '2', vod_name: 'Fresh'}]});
      // A server that drops every request does so slowly, and is asked once.
      if (req.url === '/spider/dead/3/search') { globalThis.dead = (globalThis.dead || 0) + 1; return setTimeout(() => reply(500, {message: 'socket hang up'}), 2700); }
      if (req.url === '/spider/dead/3/home') return reply(200, {class: [], list: [], asked: globalThis.dead});
      if (req.url === '/spider/site/3/search') {
        const {wd} = JSON.parse(body);
        if (wd === 'found') return reply(200, {list: [{vod_id: '1', vod_name: 'Found'}]});
        return reply(404, {statusCode: 404, message: 'Request failed with status code 404'});
      }
      reply(404, {message: `Route ${req.method}:${req.url} not found`});
    });
  });
  server.listen();
};
""")
    request = job / 'request.json'
    request.write_text(json.dumps(dict(script=str(bundle), cache=str(job), api='http://127.0.0.1:9/index.js', key='site', catPawOpen=True)))
    with open(job / 'log', 'w') as log:
        process = subprocess.Popen([str(host / 'node'), '--no-warnings', '--experimental-vm-modules', str(host / 'host.mjs'), '--serve', str(request)], stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
        try:
            assert wait(job / 'ready.json') == {'ready': True}
            def answer(ident, params):
                process.stdin.write(json.dumps(dict(id=ident, params=params)) + '\n'); process.stdin.flush()
                return wait(job / 'responses' / (ident + '.json'))
            assert json.loads(answer('found', {'catPawOpen': '/spider/site/3', 'wd': 'found'})['result'])['list'] == [{'vod_id': '1', 'vod_name': 'Found'}]
            assert json.loads(answer('none', {'catPawOpen': '/spider/site/3', 'wd': 'nothing'})['result'])['list'] == []
            assert json.loads(answer('nosearch', {'catPawOpen': '/spider/other/3', 'wd': 'x'})['result'])['list'] == []
            assert json.loads(answer('blank', {'catPawOpen': '/spider/blank/3', 'wd': 'x'})['result'])['list'] == []
            assert json.loads(answer('stale', {'catPawOpen': '/spider/stale/3', 'wd': 'x'})['result'])['list'] == [{'vod_id': '2', 'vod_name': 'Fresh'}]
            assert 'socket hang up' in answer('dead', {'catPawOpen': '/spider/dead/3', 'wd': 'x'})['error']
            assert json.loads(answer('deadhome', {'catPawOpen': '/spider/dead/3'})['result'])['asked'] == 1
            assert json.loads(answer('noinit', {'catPawOpen': '/spider/noinit/3'})['result'])['class'] == [{'type_id': '1', 'type_name': 'Films'}]
            home = answer('home', {'catPawOpen': '/spider/site/3'})
            assert 'home broke' in json.dumps(home, ensure_ascii=False), home
            process.stdin.close()
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None: process.kill(); process.wait()
print('Script host checks passed: modules, HTML parsing, persistent state, restart preferences, response protocol, CatPawOpen searches and sites without init.')
