#!/usr/bin/env python3
"""Combine every original URL and directory result into a reviewable playback report."""
import argparse,collections,datetime,html,json,pathlib
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',default='build/playback-audit');a=p.parse_args();root=pathlib.Path(a.output).resolve()
rows=[]
for imported in json.loads((root/'imports.json').read_text()):
 i=imported['index'];file=root/f'{i:02}'/'result.json';r=json.loads(file.read_text()) if file.exists() else imported
 row={**r,'evidence':str(file)};d=root/'directories'/str(i)/'result.json'
 if d.exists():
  directory=json.loads(d.read_text());row['directoryEvidence']=str(d)
  if directory.get('passed'):
   row.update(passed=True,status='directory-child-passed',childURL=directory['childURL'],playbackURL=directory['playbackURL'],source=directory['source'])
  else:row['status']='directory-no-media'
 elif r.get('passed'):row['status']='media-verified'
 elif r.get('imported'):row['status']='no-verified-media'
 else:row['status']='import-blocked'
 row['testedSourceCount']=len(r.get('testedSources',[]))
 if d.exists():row['testedSourceCount']=sum(len(x.get('test',{}).get('testedSources',[])) for x in directory.get('attempts',[]))
 rows.append(row)
counts=dict(collections.Counter(r['status'] for r in rows))
report={'completedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'All 41 supplied URLs fetched. For each importable subscription, sources tried until verified media or all sources exhausted. This run sampled up to three titles and three playback lines per source. Home and search tested independently. HLS checks fetch a referenced segment; this is not a decoder or sustained-playback test. Directory results require importing their child URL in the app.','counts':counts,'subscriptions':rows}
(root/'full-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
E=lambda v:html.escape(str(v or ''),quote=True)
labels={'media-verified':'Media verified','directory-child-passed':'Child media verified','no-verified-media':'No verified media','import-blocked':'Import blocked','directory-no-media':'Directory: no media'}
body=[]
for r in rows:
 ok=r['status'] in ('media-verified','directory-child-passed')
 reason=r.get('importError','') if r['status']=='import-blocked' else ('Import the child subscription URL.' if r['status']=='directory-child-passed' else '')
 if r['status']=='no-verified-media':reason=f"All {r.get('sources',0)} sources attempted; sampled titles did not yield verified media."
 if reason.startswith('Swift/ErrorType.swift:'):reason=reason.split('Error raised at top level: ',1)[-1]
 if 'NSURLErrorDomain Code=-1004' in reason:reason='Could not connect to the subscription server.'
 if 'NSURLErrorDomain Code=-1200' in reason:reason='TLS connection failed.'
 evidence=pathlib.Path(r.get('directoryEvidence') or r['evidence']).relative_to(root)
 links=f'<a href="{E(evidence)}">Evidence</a>'
 if r.get('playbackURL'):links+=f' · <a href="{E(r["playbackURL"])}">Media URL</a>'
 if r.get('childURL'):links+=f' · <a href="{E(r["childURL"])}">Child subscription</a>'
 body.append(f'<tr><td>{r["index"]}</td><td><a href="{E(r["url"])}">{E(r["name"])}</a></td><td class="{"ok" if ok else "bad"}">{E(labels[r["status"]])}</td><td>{E(r.get("source"))}</td><td>{r["testedSourceCount"]}</td><td>{E(reason)}<br>{links}</td></tr>')
page='''<!doctype html><html lang="en"><meta charset="utf-8"><title>Subscription playback audit</title><style>body{font:15px system-ui;margin:32px auto;max-width:1400px;padding:0 20px;color:#1c2430;background:#fafbfc}h1{font-size:28px}p{max-width:1000px;line-height:1.6}table{border-collapse:collapse;width:100%;background:white}th,td{text-align:left;border-bottom:1px solid #dce1e8;padding:12px;vertical-align:top}th{background:#edf1f6;position:sticky;top:0}td:nth-child(2){min-width:130px}td:last-child{max-width:500px;overflow-wrap:anywhere;font-size:13px}a{color:#1856a5}.ok{color:#17613c;font-weight:600}.bad{color:#904810}small{color:#536071}</style><h1>Subscription playback audit</h1>'''
page+=f'<p><b>{counts.get("media-verified",0)} individual subscriptions produced verified media.</b> {counts.get("directory-child-passed",0)} directories led to a verified child subscription. {counts.get("no-verified-media",0)} imported but did not yield verified media; {counts.get("import-blocked",0)} could not be imported.</p>'
page+=f'<p>{E(report["scope"])} Media links can expire and may require the headers saved in the evidence.</p><p><a href="full-results.json">Full JSON report</a> · <a href="media-rechecks.json">Final media rechecks</a></p><table><thead><tr><th>#</th><th>Subscription</th><th>Result</th><th>Working source</th><th>Sources tried</th><th>Details</th></tr></thead><tbody>'+''.join(body)+'</tbody></table></html>'
(root/'report.html').write_text(page)
print(json.dumps(counts));print('Report:',root/'report.html')
