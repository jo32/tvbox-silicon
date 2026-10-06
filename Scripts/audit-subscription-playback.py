#!/usr/bin/env python3
"""Fetch every supplied subscription and seek one verified media response per subscription.
Uses TVCore's importer and the same persistent Java/JS hosts as the app. Each source
gets home/search, category fallback, up to four titles and three playback lines.
Stops a subscription only after media verification or after its sources are exhausted.
"""
import argparse, concurrent.futures, importlib.util, json, pathlib, subprocess, time, urllib.parse, urllib.request, hashlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('source_audit',ROOT/'Scripts/audit-source-loading.py')
host=importlib.util.module_from_spec(spec);spec.loader.exec_module(host)
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--inputs',default=str(ROOT/'Fixtures/subscription-audit.txt'))
p.add_argument('--output',default=str(ROOT/'build/playback-audit'))
p.add_argument('--workers',type=int,default=3)
p.add_argument('--resume',action='store_true')
p.add_argument('--all-sources',action='store_true',help='Continue after a successful source for source-by-source comparison')
p.add_argument('--source-workers',type=int,default=1,help='Concurrent sources per subscription with --all-sources (default: 1)')
a=p.parse_args();OUT=pathlib.Path(a.output).resolve();OUT.mkdir(parents=True,exist_ok=True)
if a.source_workers < 1:p.error('--source-workers must be at least 1')

def save(path,data):path.write_text(json.dumps(data,ensure_ascii=False,indent=2))
def log(text):print(text,flush=True)
def fetch_config(row):
 folder=OUT/f"{row['index']:02}";folder.mkdir(exist_ok=True);path=folder/'subscription.json'
 if a.resume and path.exists():return json.loads(path.read_text())
 url=row['url']
 if url.startswith('https:/') and not url.startswith('https://'):
  url=url.replace('https:/','https://',1);row['correctedURL']=url
 try:
  r=subprocess.run([str(ROOT/'.build/debug/TVBoxProbe'),'--subscription-export',url],capture_output=True,text=True,timeout=65)
  if r.returncode:raise ValueError(r.stderr.split('\n')[0][:500])
  c=json.loads(r.stdout);save(path,c);row['imported']=True;row['sources']=len(c['sites']);return c
 except Exception as e:row['importError']=str(e)[:500];return None

def headers_for(site,play):
 h=dict(site.get('header') or {});extra=play.get('header') or {}
 if isinstance(extra,str):
  try:extra=json.loads(extra)
  except ValueError:extra={}
 if isinstance(extra,dict):h.update(extra)
 if play.get('ua') or play.get('UA'):h['User-Agent']=play.get('ua') or play.get('UA')
 return {k:str(v) for k,v in h.items()}
def media(url,headers,depth=0):
 if not url.startswith(('https://','http://')):raise ValueError('Not an HTTP media URL')
 req=urllib.request.Request(host.address(url,url),headers={'User-Agent':'Mozilla/5.0',**headers,'Range':'bytes=0-65535'})
 with urllib.request.urlopen(req,timeout=20) as r:
  data=r.read(65536);status=r.status;kind=r.headers.get('Content-Type','');final=r.url
 result={'url':url,'finalURL':final,'status':status,'contentType':kind,'bytesRead':len(data)}
 if data.lstrip().startswith(b'#EXTM3U'):
  result['format']='HLS';lines=data.decode('utf-8-sig','replace').splitlines()
  target=next((l.strip() for l in lines if l.strip() and not l.startswith('#')),None)
  if not target:raise ValueError('Empty HLS playlist')
  if depth<2:result['child']=media(urllib.parse.urljoin(final,target),headers,depth+1)
  return result
 if (len(data)>188 and data[0]==71 and data[188]==71) or b'ftyp' in data[:32] or data.startswith((b'ID3',b'\x1aE\xdf\xa3',b'OggS',b'FLV')) or (len(data)>1 and data[0]==255 and data[1]&224==224):result['format']='media';return result
 if kind.startswith(('video/','audio/')) and data and not data.lstrip().startswith((b'<',b'{',b'[')):result['format']='media-content-type';return result
 raise ValueError('HTTP response is not recognizable media: '+kind)

def source_test(site,c,folder):
 folder.mkdir(exist_ok=True);result={'key':site['key'],'name':site.get('name'),'api':site['api'],'attempts':[]};session=None;start=time.monotonic();stage='initialize';n=0
 def call(params,label):
  nonlocal n
  n+=1;return session.call(params,f'{n:02}-{label}')
 try:
  session=host.Session(site,c,folder);videos=[];classes=[];stage='discovery'
  for label,params in [('home',{'filter':'true'} if site['type']==4 else {}),('search',{'wd':'我的','pg':'1','quick':'false'})]:
   if label=='search' and str(site.get('searchable',1))=='0':continue
   try:
    d=call(params,label);items=d.get('list') or [];videos=(items[:2]+videos+items[2:]) if label=='search' else videos+items;classes.extend(d.get('class') or []);result[label]={'videos':len(items),'categories':len(d.get('class') or [])}
   except Exception as e:result[label]={'error':str(e)[:400]}
  if not videos:
   for cat in classes[:3]:
    try:videos.extend(call({'ac':'detail','t':str(cat['type_id']),'pg':'1'},'category').get('list') or [])
    except Exception as e:result['attempts'].append({'stage':'category','error':str(e)[:250]})
    if videos:break
  ids=set();candidates=[]
  for v in videos:
   ident=str(v.get('vod_id',''))
   if ident and ident not in ids and not v.get('action'):ids.add(ident);candidates.append(v)
  result['candidateCount']=len(candidates)
  if not candidates:raise ValueError('No videos from home, search, or categories')
  for v in candidates[:4]:
   stage='detail';attempt={'title':v.get('vod_name'),'id':v['vod_id']};result['attempts'].append(attempt)
   try:
    d=call({'ac':'detail','ids':str(v['vod_id'])},'detail');items=d.get('list') or []
    if not items:raise ValueError('No detail entries')
    item=items[0];flags=(item.get('vod_play_from') or '').split('$$$');groups=(item.get('vod_play_url') or '').split('$$$');attempt['playback']=[]
    for i,group in enumerate(groups[:3]):
     episodes=[e for e in group.split('#') if e]
     if not episodes:continue
     address=episodes[0].split('$',1)[-1];flag=flags[i] if i<len(flags) else '';stage='play'
     pr={'flag':flag};attempt['playback'].append(pr)
     try:
      play=call({'play':address,'flag':flag,'detailID':str(v['vod_id'])},'play') if site['type'] in (3,4) else {'url':address,'parse':0}
      pr['response']=play;url=play.get('url');urls=url[1::2] if isinstance(url,list) else [url]
      prefix=play.get('playUrl') or (site.get('playUrl','') if site['type'] not in (3,4) else '')
      urls=[prefix+u if isinstance(u,str) else u for u in urls]
      for u in urls[:2]:
       if not isinstance(u,str) or not u.startswith(('http://','https://')):continue
       pr['resolvedURL']=u;stage='media'
       parts=urllib.parse.urlsplit(u)
       if parts.hostname in ('localhost','127.0.0.1') and parts.path=='/proxy':
        query=urllib.parse.parse_qs(parts.query)
        if query.get('do')==['m3u8'] and query.get('url'):u=query['url'][0];pr['unwrappedURL']=u
       try:
        verified=media(u,headers_for(site,play));pr['media']=verified;result['passed']=True;result['playbackURL']=u;result['title']=v.get('vod_name');return result
       except Exception as e:pr['mediaError']=str(e)[:400]
      if not pr.get('resolvedURL'):pr['error']='No HTTP playback URL returned'
     except Exception as e:pr['error']=str(e)[:400]
   except Exception as e:attempt['error']=str(e)[:400]
  result['error']='No verified media from tested titles/lines'
 except Exception as e:result['error']=str(e)[:500]
 finally:
  if session:session.close()
  result['lastStage']=stage;result['seconds']=round(time.monotonic()-start,1);save(folder/'result.json',result)
 return result

# Prior results only determine order; every success is verified afresh.
prior={}
for name in ('moyu-full','search-coverage'):
 f=ROOT/'build/runtime-audit'/name/'results.json'
 if f.exists():
  for r in json.loads(f.read_text()):prior[(r['subscription'],r['key'])]=(r.get('search',{}).get('videos',0)>0)*2+(r.get('home',{}).get('videos',0)>0)

def test_subscription(pair):
 row,c=pair;folder=OUT/f"{row['index']:02}";final=folder/'result.json'
 if a.resume and final.exists():return json.loads(final.read_text())
 row['testedSources']=[]
 if c:
  row['imported']=True;row['sources']=len(c['sites'])
  sites=[s['raw'] for s in c['sites']]
  def rank(s):
   name=s['api'].lower()+' '+s['key'].lower()
   direct=any(k in name for k in ('libvio','newcz','guazi','360','zhiqiu','量子','非凡','荐片'))
   cloud=any(k in name for k in ('wogg','pan','夸克','玩偶','seed','quark'))
   return (int(direct)-int(cloud),prior.get((c['origin'],s['key']),0))
  sites.sort(key=rank,reverse=True)
  existing={}
  if a.resume:
   for f in folder.glob('source-*/result.json'):
    old=json.loads(f.read_text());existing[old['key']]=(old,f.parent)
  def run_source(s):
   subfolder=folder/('source-'+hashlib.sha256(s['key'].encode()).hexdigest()[:10])
   if s['key'] in existing:r,subfolder=existing[s['key']]
   else:r=source_test(s,c,subfolder)
   return r,subfolder
  with concurrent.futures.ThreadPoolExecutor(a.source_workers if a.all_sources else 1) as pool:
   completed=pool.map(run_source,sites) if a.all_sources else map(run_source,sites)
   for i,(r,subfolder) in enumerate(completed):
    row['testedSources'].append({'key':r['key'],'passed':r.get('passed',False),'evidence':str(subfolder/'result.json'),'error':r.get('error')})
    log(f"{row['index']:02} {row['name']} {i+1}/{len(sites)} {r['key']}: {'MEDIA OK' if r.get('passed') else r.get('error')}")
    if r.get('passed'):
     row['passed']=True;row['playbackURL']=r['playbackURL'];row['source']=r['key'];row['title']=r.get('title')
     if not a.all_sources:break
 row['passedSources']=sum(r['passed'] for r in row['testedSources'])
 row['testedSourceCount']=len(row['testedSources'])
 row.setdefault('passed',False);save(final,row);return row
def main():
 rows=[dict(index=i+1,name=line.split('|',1)[0],url=line.split('|',1)[1]) for i,line in enumerate(pathlib.Path(a.inputs).read_text().splitlines()) if line.strip()]
 with concurrent.futures.ThreadPoolExecutor(6) as pool:configs=list(pool.map(fetch_config,rows))
 save(OUT/'imports.json',rows)
 log(f'Fetched all {len(rows)} subscriptions; {sum(c is not None for c in configs)} imported.')
 with concurrent.futures.ThreadPoolExecutor(a.workers) as pool:
  results=[]
  for r in pool.map(test_subscription,zip(rows,configs)):
   results.append(r);save(OUT/'results.json',results)
 log(f"FINISHED: {sum(r['passed'] for r in results)}/{len(results)} subscriptions returned verified media.")

if __name__=='__main__':main()
