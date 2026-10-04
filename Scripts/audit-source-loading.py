#!/usr/bin/env python3
"""Read exported TVCore Subscription snapshots; test home and search independently.
No playback or login actions. Keeps raw host evidence; empty results aren't successes.
"""
import argparse, concurrent.futures, hashlib, json, pathlib, shutil, subprocess, tempfile, threading, time, urllib.parse
ROOT=pathlib.Path(__file__).resolve().parents[1]
assets=ROOT/'build/runtime-audit/downloads';assets.mkdir(parents=True,exist_ok=True)
converted=ROOT/'build/runtime-audit/converted';converted.mkdir(exist_ok=True)
locks={};lock=threading.Lock()
def address(value,base):
 u=urllib.parse.urljoin(base,value);s=urllib.parse.urlsplit(u)
 return urllib.parse.urlunsplit((s.scheme,s.netloc.encode('idna').decode(),urllib.parse.quote(s.path,safe='/%'),urllib.parse.quote(s.query,safe='=&%+/?:@'),s.fragment))
def download(url):
 key=hashlib.sha256(url.encode()).hexdigest()
 with lock:l=locks.setdefault(key,threading.Lock())
 with l:
  f=assets/key
  if not f.exists():
   r=subprocess.run(['curl','-fsSL','--max-time','30','--max-filesize','20000000','-A','Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36','-o',str(f)+'.tmp',url],capture_output=True,text=True)
   if r.returncode:raise RuntimeError('Plugin download: '+r.stderr.strip())
   pathlib.Path(str(f)+'.tmp').replace(f)
  return str(f)
class Session:
 def __init__(self,site,config,folder):
  self.folder=folder;self.process=None;self.log=None
  self.native=site['type'] in [1,4];self.site=site;self.base=config['origin']
  if self.native:return
  if site['type']!=3:raise RuntimeError('Unsupported source type '+str(site['type']))
  script=not site['api'].startswith('csp_')
  plugin=site['api'] if script else site.get('jar') or config['raw'].get('spider','')
  if not plugin:raise RuntimeError('No plugin archive')
  url=address(plugin.split(';md5;')[0],self.base);local=download(url)
  def resolve(value):
   if isinstance(value,dict):return {k:resolve(v) for k,v in value.items()}
   if isinstance(value,list):return [resolve(v) for v in value]
   if isinstance(value,str) and value.startswith(('./','../','//')):return address(value,self.base)
   return value
  ext=resolve(site.get('ext',''))
  if not isinstance(ext,str):ext=json.dumps(ext,ensure_ascii=False,separators=(',',':'))
  elif ext.startswith(('./','../','//')) or (script and ext and not ext.startswith('{')):ext=address(ext,self.base)
  request=dict(jar=local,script=local,api=url if script else site['api'],key=site['key'],ext=ext,cache=str(folder),conversionCache=str(converted))
  (folder/'request.json').write_text(json.dumps(request,ensure_ascii=False))
  host=ROOT/'build/JavaHost'
  cmd=[str(host/'jre/bin/java'),'-Xmx1536m','--add-opens','java.base/java.lang=ALL-UNNAMED','--add-opens','java.base/sun.net.www.protocol.jar=ALL-UNNAMED','-Dorg.slf4j.simpleLogger.defaultLogLevel=error','-cp',str(host/'host.jar')+':'+str(host/'lib/*'),'tvbox.runtime.NativeProbe','--serve',str(folder/'request.json')]
  if script:
   host=ROOT/'build/ScriptHost';cmd=[str(host/'node'),'--no-warnings','--experimental-vm-modules',str(host/'host.mjs'),'--serve',str(folder/'request.json')]
  self.log=(folder/'host.log').open('w');self.process=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=self.log,stderr=self.log,text=True)
  try:
   ready=self.wait(folder/'ready.json',180)
   if ready.get('error'):raise RuntimeError(ready['error'])
  except BaseException:self.close();raise
 def wait(self,file,timeout):
  until=time.monotonic()+timeout
  while time.monotonic()<until:
   if file.exists():return json.loads(file.read_text())
   if self.process.poll() is not None:raise RuntimeError('Plugin exited; see host.log')
   time.sleep(.1)
  raise RuntimeError(f'Plugin timeout after {timeout}s')
 def call(self,params,stage):
  if self.native:
   values=dict(params);ext=self.site.get('ext')
   if ext is not None:values['extend']=ext if isinstance(ext,str) else json.dumps(ext,ensure_ascii=False,separators=(',',':'))
   url=address(self.site['api'],self.base);parts=urllib.parse.urlsplit(url)
   query=[(k,v) for k,v in urllib.parse.parse_qsl(parts.query) if k not in values]+list(values.items())
   url=urllib.parse.urlunsplit((parts.scheme,parts.netloc,parts.path,urllib.parse.urlencode(query),''))
   cmd=['curl','-fsSL','--max-time','25','--max-filesize','20000000','-A','Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36']
   for k,v in self.site.get('header',{}).items():cmd+=['-H',f'{k}: {v}']
   r=subprocess.run(cmd+[url],capture_output=True,text=True)
   if r.returncode:raise RuntimeError(r.stderr.strip())
   text=r.stdout
  else:
   self.process.stdin.write(json.dumps(dict(id=stage,params=params))+'\n');self.process.stdin.flush()
   try:result=self.wait(self.folder/'responses'/f'{stage}.json',60)
   except BaseException:self.close();raise
   if 'error' in result:raise RuntimeError(result['error'])
   text=result.get('result','')
  (self.folder/f'{stage}.json').write_text(text)
  return json.loads(text)
 def close(self):
  if self.process:
   try:self.process.stdin.close();self.process.wait(timeout=2)
   except (BrokenPipeError,subprocess.TimeoutExpired):self.process.kill();self.process.wait()
   self.process=None
  if self.log:self.log.close();self.log=None

def test(item):
 ident,config,site=item;folder=out/ident;folder.mkdir(exist_ok=True)
 result=dict(id=ident,subscription=config['origin'],key=site['key'],name=site.get('name'),api=site['api']);session=None;t=time.monotonic()
 try:
  session=Session(site,config,folder);result['initialized']=True
  for stage,params in [('home',{'filter':'true'} if site['type']==4 else {}),('search',{'wd':a.query,'pg':'1','quick':'false'})]:
   if stage=='search' and str(site.get('searchable',1))!='1':result['search']={'skipped':'searchable disabled'};continue
   try:
    d=session.call(params,stage);result[stage]={'videos':len(d.get('list') or []),'categories':len(d.get('class') or [])}
   except Exception as e:result[stage]={'error':str(e)[:500]}
 except Exception as e:result['initializationError']=str(e)[:500]
 finally:
  if session:session.close()
 result['seconds']=round(time.monotonic()-t,1);(folder/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
 print(json.dumps(result,ensure_ascii=False),flush=True);return result
def main():
 global a,out
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('snapshots',nargs='+');p.add_argument('--output',required=True);p.add_argument('--workers',type=int,default=3);p.add_argument('--limit',type=int);p.add_argument('--query',default='我的');p.add_argument('--keys',nargs='*');p.add_argument('--searchable-only',action='store_true')
 a=p.parse_args();out=pathlib.Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True)
 jobs=[]
 for path in a.snapshots:
  file=pathlib.Path(path);c=json.loads(file.read_text());sites=[s['raw'] for s in c['sites']]
  if a.searchable_only:sites=[s for s in sites if str(s.get('searchable',1))=='1' and s.get('type') in [1,3,4]]
  if a.keys:sites=[s for s in sites if s['key'] in a.keys]
  if a.limit:sites=sites[:a.limit]
  jobs.extend((file.stem+f'-{i:03}',c,s) for i,s in enumerate(sites))
 with concurrent.futures.ThreadPoolExecutor(a.workers) as pool:results=list(pool.map(test,jobs))
 (out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
