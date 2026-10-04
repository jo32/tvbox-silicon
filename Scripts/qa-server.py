#!/usr/bin/env python3
"""Deterministic local API/playlists/media for manual app QA; binds only to loopback."""
import argparse
import json
import pathlib
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=8765)
args = parser.parse_args()
base = f'http://127.0.0.1:{args.port}'
lock = threading.Lock()
counts = {}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *values):
        print(fmt % values, flush=True)

    def send(self, body, status=200, mime='application/json'):
        if isinstance(body, (dict, list)): body = json.dumps(body, ensure_ascii=False).encode()
        if isinstance(body, str): body = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        q = {k:v[0] for k,v in parse_qs(parsed.query).items()}
        with lock:
            counts[path] = counts.get(path, 0) + 1
            count = counts[path]
        if path == '/config.json':
            return self.send({'sites': [
                {'key':'qa-index','name':'片单推荐 / Discover','type':4,'api':base+'/index','indexs':1,'searchable':0},
                {'key':'qa-standard','name':'标准视频 / Movies','type':4,'api':base+'/api'},
                {'key':'qa-slow','name':'慢速加载 / Slow','type':4,'api':base+'/slow'},
                {'key':'qa-empty','name':'空结果 / Empty','type':4,'api':base+'/empty'},
                {'key':'qa-error','name':'失败重试 / Unavailable','type':4,'api':base+'/failure'},
                {'key':'qa-unsupported','name':'不支持的格式 / Unsupported','type':0,'api':base+'/unsupported'}
            ],'lives':[
                {'name':'测试频道 / Channels','url':base+'/live.m3u'},
                {'name':'空播放列表 / Empty','url':base+'/empty.m3u'},
                {'name':'不可用播放列表 / Unavailable','url':base+'/failure.m3u'}
            ]})
        if path == '/empty-config.json': return self.send({'sites': [], 'lives': [{'name':'测试频道','url':base+'/live.m3u'}]})
        if path == '/invalid.json': return self.send('{invalid JSON')
        if path == '/empty.m3u': return self.send('#EXTM3U', mime='audio/x-mpegurl')
        if path == '/failure.m3u': return self.send('Unavailable',503,'text/plain')
        if path == '/live.m3u':
            lines=['#EXTM3U']
            for i in range(1,19):
                group=['新闻','电影','Sports'][i%3]
                lines += [f'#EXTINF:-1 tvg-logo="{base}/poster.png" group-title="{group}",测试频道 {i:02d}',f'{base}/clip.mp4?channel={i}']
            lines += ['#EXTINF:-1 group-title="故障测试",无法播放的频道',base+'/missing.mp4']
            return self.send('\n'.join(lines),mime='audio/x-mpegurl')
        if path == '/poster.png':
            return self.send((root/'Design/yingxia-icon.png').read_bytes(),mime='image/png')
        if path == '/clip.mp4':
            media=root/'build/player-test.mp4'
            if not media.exists(): return self.send('Generate clip with Scripts/test-player.sh first',404,'text/plain')
            size=media.stat().st_size
            match=re.match(r'bytes=(\d+)-(\d*)',self.headers.get('Range',''))
            start=int(match[1]) if match else 0
            end=min(int(match[2]) if match and match[2] else size-1,size-1)
            if start>=size:
                self.send_response(416);self.send_header('Content-Range',f'bytes */{size}');self.end_headers();return
            self.send_response(206 if match else 200)
            self.send_header('Content-Type','video/mp4');self.send_header('Accept-Ranges','bytes')
            self.send_header('Content-Length',str(end-start+1))
            if match:self.send_header('Content-Range',f'bytes {start}-{end}/{size}')
            self.end_headers()
            with media.open('rb') as stream:
                stream.seek(start)
                try:self.wfile.write(stream.read(end-start+1))
                except (BrokenPipeError,ConnectionResetError):pass
            return
        if path == '/missing.mp4': return self.send('Not found',404,'text/plain')
        if path == '/failure': return self.send('Service unavailable',503,'text/plain')
        if path in ['/api','/slow','/empty','/index']:
            if path=='/slow':time.sleep(2)
            categories=[{'type_id':'movies','type_name':'电影'},{'type_id':'series','type_name':'电视剧'},{'type_id':'empty','type_name':'空分类'}]
            if 'play' in q:return self.send({'parse':0,'url':base+'/clip.mp4'})
            if 'ids' in q:
                return self.send({'list':[{'vod_id':q['ids'],'vod_name':'测试影片 '+q['ids'],'vod_pic':base+'/poster.png',
                    'vod_content':'这是一段用于检查详情页布局的简介。 '*24,
                    'vod_play_from':'线路一$$$线路二','vod_play_url':'#'.join(f'第 {i} 集$episode-{i}' for i in range(1,37))+'$$$备用$alternate'}]})
            if path=='/empty' or q.get('t')=='empty' or q.get('wd') in ['没有这个','notfound']:
                return self.send({'class':categories,'list':[],'pagecount':1})
            pg=int(q.get('pg','1'))
            title=q.get('wd') or ('剧集' if q.get('t')=='series' else '测试影片')
            videos=[{'vod_id':str((pg-1)*12+i),'vod_name':f'{title} {i:02d}', 'vod_pic':base+'/poster.png','vod_remarks':'更新至 36 集' if i%2 else '1080P'} for i in range(1,13)]
            if path=='/index':
                videos=[{'vod_name':'测试影片','vod_pic':base+'/poster.png','vod_remarks':'7.8'},{'vod_name':'剧集','vod_pic':base+'/poster.png'}]
            return self.send({'class':categories,'list':videos,'pagecount':3 if path!='/index' else 1})
        return self.send('Not found',404,'text/plain')

print(f'QA subscription: {base}/config.json',flush=True)
ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
