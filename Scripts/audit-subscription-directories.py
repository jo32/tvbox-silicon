#!/usr/bin/env python3
"""Follow valid directory roots until a child subscription yields verified media."""
import importlib.util,json,pathlib,subprocess,sys,concurrent.futures
ROOT=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('playback',ROOT/'Scripts/audit-subscription-playback.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
OUT=p.OUT/'directories';OUT.mkdir(exist_ok=True)

def uncomment(s):
 out=[];i=0;quoted=False
 while i<len(s):
  if quoted:
   out.append(s[i])
   if s[i]=='\\' and i+1<len(s):i+=1;out.append(s[i])
   elif s[i]=='"':quoted=False
   i+=1
  elif s[i]=='"':quoted=True;out.append(s[i]);i+=1
  elif s[i:i+2]=='//':
   j=s.find('\n',i);i=len(s) if j<0 else j
  elif s[i:i+2]=='/*':
   j=s.find('*/',i+2)
   if j<0:raise ValueError('Unclosed comment')
   out.append(' ');i=j+2
  else:out.append(s[i]);i+=1
 return ''.join(out)
def directory(url,file):
 r=subprocess.run(['curl','-fsSL','--max-time','30','--max-filesize','20000000','-A','okhttp/3.12.13',p.host.address(url,url)],capture_output=True)
 if r.returncode:raise ValueError(r.stderr.decode()[:250])
 file.write_bytes(r.stdout);d=json.loads(uncomment(r.stdout.decode('utf-8-sig')))
 return [(v.get('name') or v.get('sourceName'),v.get('url') or v.get('sourceUrl')) for v in (d.get('urls') or d.get('storeHouse') or [])]
def run(root):
 folder=OUT/str(root['index']);folder.mkdir(exist_ok=True);queue=[(root['name'],root['url'],0)];seen=set();report={'index':root['index'],'name':root['name'],'url':root['url'],'directory':True,'attempts':[]}
 while queue:
  name,url,depth=queue.pop(0)
  if url in seen or depth>3:continue
  seen.add(url);n=len(seen);row={'index':root['index']*100+n,'name':name,'url':url}
  c=p.fetch_config(row);attempt={'url':url,'name':name};report['attempts'].append(attempt)
  if c:
   # Same freshly fetched document may already have a successful full test.
   reused=None
   for f in p.OUT.glob('[0-9]*/result.json'):
    result=json.loads(f.read_text());config=f.parent/'subscription.json'
    if result.get('passed') and config.exists():
     old=json.loads(config.read_text())
     if old['origin']==c['origin'] and old['raw']==c['raw']:reused=result;attempt['reusedEvidence']=str(f);break
   tested=reused or p.test_subscription((row,c));attempt['test']=tested
   if tested.get('passed'):
    report.update(passed=True,childURL=url,source=tested['source'],playbackURL=tested['playbackURL']);break
  else:
   attempt['importError']=row.get('importError')
   try:
    entries=directory(url,folder/f'{n:03}.body');attempt['children']=len(entries)
    # Known working subscription first; other links remain in queue until success.
    entries.sort(key=lambda e:0 if ('摸鱼儿' in (e[1] or '') or 'moyu' in (e[1] or '') or '/my' in (e[1] or '')) else 1)
    queue.extend((nm or u,p.host.address(u,url),depth+1) for nm,u in entries if u)
   except Exception as e:attempt['fetchError']=str(e)[:300]
  p.save(folder/'progress.json',report)
 report.setdefault('passed',False);p.save(folder/'result.json',report);p.log(f"DIRECTORY {root['index']} {root['name']}: {report['passed']}");return report
rows=json.loads((p.OUT/'imports.json').read_text());roots=[r for r in rows if 'subscription directory' in r.get('importError','')]
with concurrent.futures.ThreadPoolExecutor(2) as pool:results=list(pool.map(run,roots))
p.save(OUT/'results.json',results)
