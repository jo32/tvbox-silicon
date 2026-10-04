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
                call({'ids': 'chosen'})
                assert call({'play': 'opaque'})['url'] == 'https://example.com/chosen.mp4'
                assert call({'wd': 'test'})['list'] == [{'vod_id':'https://example.com/one', 'vod_name':'One'}, {'vod_id':'https://example.com/two', 'vod_name':'Two'}]
                process.stdin.close()
                assert process.wait(timeout=5) == 0
            finally:
                if process.poll() is None: process.kill(); process.wait()
print('Script host checks passed: modules, HTML parsing, persistent state, restart preferences, response protocol.')
