#!/usr/bin/env python3
"""captions.py — export the engine's transcript to editor-compatible formats.

Reuses the broadcast cue segmentation (srt_broadcast.build_cues) and renders:
  srt    — SubRip (DaVinci Resolve, Premiere, Final Cut, everything)
  vtt    — WebVTT (HTML <track>, browsers, editors)
  itt    — iTunes Timed Text / TTML (Final Cut Pro & Premiere native captions)
  fcpxml — Final Cut Pro project with a caption track
  html   — self-contained interactive transcript (speaker colors, timestamps,
           low-confidence amber — from the word/spk_seg/conf events directly)

Every XML format is validated (ElementTree parse) before it's written.

Usage:
  captions.py <events.jsonl> --fmt srt,vtt,itt,fcpxml,html --out-base out [--fps 30]
"""
import json, sys, argparse, html as htmllib, xml.etree.ElementTree as ET
from srt_broadcast import load_words, build_cues, dwidth

# ── time formatters ──────────────────────────────────────────────────────────
def tc_srt(t): h=int(t//3600);m=int(t%3600//60);s=int(t%60);ms=round((t-int(t))*1000); return f"{h:02d}:{m:02d}:{s:02d},{ms%1000:03d}"
def tc_vtt(t): h=int(t//3600);m=int(t%3600//60);s=int(t%60);ms=round((t-int(t))*1000); return f"{h:02d}:{m:02d}:{s:02d}.{ms%1000:03d}"
def tc_ttml(t): h=int(t//3600);m=int(t%3600//60);s=int(t%60);ms=round((t-int(t))*1000); return f"{h:02d}:{m:02d}:{s:02d}.{ms%1000:03d}"

# ── renderers ────────────────────────────────────────────────────────────────
def to_srt(cues):
    out=[]
    for i,(s,e,lines) in enumerate(cues,1):
        out.append(f"{i}\n{tc_srt(s)} --> {tc_srt(e)}\n"+"\n".join(lines)+"\n")
    return "\n".join(out)

def to_vtt(cues):
    out=["WEBVTT",""]
    for i,(s,e,lines) in enumerate(cues,1):
        out.append(f"{i}\n{tc_vtt(s)} --> {tc_vtt(e)}\n"+"\n".join(lines)+"\n")
    return "\n".join(out)

def to_itt(cues, lang):
    NS="http://www.w3.org/ns/ttml"
    tts="http://www.w3.org/ns/ttml#styling"; ttp="http://www.w3.org/ns/ttml#parameter"
    ET.register_namespace('', NS); ET.register_namespace('tts', tts); ET.register_namespace('ttp', ttp)
    tt=ET.Element(f"{{{NS}}}tt", {f"{{http://www.w3.org/XML/1998/namespace}}lang":lang,
        f"{{{ttp}}}timeBase":"media", f"{{{tts}}}extent":"1920 1080"})
    head=ET.SubElement(tt,f"{{{NS}}}head")
    st=ET.SubElement(head,f"{{{NS}}}styling")
    ET.SubElement(st,f"{{{NS}}}style",{f"{{http://www.w3.org/XML/1998/namespace}}id":"basic",
        f"{{{tts}}}color":"white", f"{{{tts}}}fontSize":"100%"})
    lay=ET.SubElement(head,f"{{{NS}}}layout")
    ET.SubElement(lay,f"{{{NS}}}region",{f"{{http://www.w3.org/XML/1998/namespace}}id":"bottom",
        f"{{{tts}}}displayAlign":"after", f"{{{tts}}}textAlign":"center"})
    body=ET.SubElement(tt,f"{{{NS}}}body"); div=ET.SubElement(body,f"{{{NS}}}div")
    for s,e,lines in cues:
        p=ET.SubElement(div,f"{{{NS}}}p",{"begin":tc_ttml(s),"end":tc_ttml(e),"style":"basic","region":"bottom"})
        p.text=lines[0]
        for ln in lines[1:]:
            br=ET.SubElement(p,f"{{{NS}}}br"); br.tail=ln
    return '<?xml version="1.0" encoding="UTF-8"?>\n'+ET.tostring(tt,encoding="unicode")

def to_fcpxml(cues, fps, lang):
    total = cues[-1][1] if cues else 0
    fcpxml=ET.Element("fcpxml",{"version":"1.10"})
    res=ET.SubElement(fcpxml,"resources")
    ET.SubElement(res,"format",{"id":"r1","name":"FFVideoFormat1080p","frameDuration":f"1/{int(fps)}s","width":"1920","height":"1080"})
    lib=ET.SubElement(fcpxml,"library"); ev=ET.SubElement(lib,"event",{"name":"Sovereign"})
    proj=ET.SubElement(ev,"project",{"name":"Transcript"})
    seq=ET.SubElement(proj,"sequence",{"format":"r1","duration":f"{round(total*fps)}/{int(fps)}s"})
    spine=ET.SubElement(seq,"spine")
    gap=ET.SubElement(spine,"gap",{"name":"Gap","offset":"0s","duration":f"{round(total*fps)}/{int(fps)}s"})
    for i,(s,e,lines) in enumerate(cues,1):
        cap=ET.SubElement(gap,"caption",{"name":f"cap{i}","offset":f"{round(s*fps)}/{int(fps)}s",
            "duration":f"{max(1,round((e-s)*fps))}/{int(fps)}s","role":"captions"})
        txt=ET.SubElement(cap,"text"); txt.text="\n".join(lines)
    return '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n'+ET.tostring(fcpxml,encoding="unicode")

SPK_COLORS=["#007AFF","#FF9500","#28CD41","#AF52DE","#FF2D55","#30B0C7","#FF3B30","#5856D6"]
def to_html(words, spk_segs, meta, low_conf=0.55):
    segs=sorted(spk_segs,key=lambda x:x['t0'])
    def spk_at(t):
        cur=-1
        for sg in segs:
            if sg['t0']<=t: cur=sg['spk']
            else: break
        return cur
    rows=[]; last=-2
    for w in words:
        sp=spk_at(w['t0'])
        if sp!=last:
            rows.append({'spk':sp,'words':[]}); last=sp
        rows[-1]['words'].append(w)
    body=[]
    for r in rows:
        c=SPK_COLORS[r['spk']%8] if r['spk']>=0 else "#9DA7B3"
        ws=[]
        for w in r['words']:
            low=w['conf']<low_conf
            style=f"color:{'#FF9F0A' if low else '#E6EDF3'};{'text-decoration:underline dotted;' if low else ''}"
            ws.append(f'<span data-t="{w["t0"]:.2f}" title="{w["conf"]*100:.0f}% · {w["t0"]:.2f}s" style="{style}">{htmllib.escape(w["text"].strip())}</span>')
        ts=r['words'][0]['t0'] if r['words'] else 0
        body.append(f'<div class="row"><span class="spk" style="color:{c};border-color:{c}">화자 {r["spk"] if r["spk"]>=0 else "?"}</span>'
                    f'<span class="ts">{int(ts//60):02d}:{int(ts%60):02d}</span><span class="tx">{" ".join(ws)}</span></div>')
    model=meta.get('model','') if meta else ''
    return f"""<!doctype html><html lang="ko"><head><meta charset="utf-8">
<title>Sovereign 전사</title><style>
body{{background:#0E1217;color:#E6EDF3;font-family:-apple-system,'Apple SD Gothic Neo','Noto Sans KR',sans-serif;max-width:860px;margin:0 auto;padding:28px;line-height:1.85}}
h1{{font-size:18px}}.meta{{color:#5C6773;font-size:12px;margin-bottom:20px}}
.row{{display:flex;gap:10px;margin-bottom:14px;align-items:baseline}}
.spk{{font-size:11px;font-weight:700;border:1px solid;border-radius:6px;padding:0 7px;white-space:nowrap}}
.ts{{color:#5C6773;font-size:11px;font-variant-numeric:tabular-nums;white-space:nowrap}}
.tx{{flex:1}} .tx span{{cursor:default}}
.legend{{color:#5C6773;font-size:11px;margin-top:24px;border-top:1px solid #283039;padding-top:10px}}
.legend b{{color:#FF9F0A}}</style></head><body>
<h1>Sovereign 전사</h1><div class="meta">{htmllib.escape(model)} · {len(words)} 단어 · {len(rows)} 발화</div>
{''.join(body)}
<div class="legend"><b>호박색 밑줄</b> = 낮은 신뢰도(검토 권장, &lt;{int(low_conf*100)}%). 단어에 마우스를 올리면 신뢰도·시각.</div>
</body></html>"""

# ── main ─────────────────────────────────────────────────────────────────────
if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('events'); ap.add_argument('--out-base',default='out')
    ap.add_argument('--fmt',default='srt,vtt,itt,fcpxml,html')
    ap.add_argument('--fps',type=float,default=30); ap.add_argument('--cps',type=float,default=17)
    ap.add_argument('--max-line',type=int,default=42); ap.add_argument('--lang',default='ko')
    a=ap.parse_args()
    words_t=load_words(a.events)
    cues=build_cues(words_t,a.cps,a.max_line,0.83,7.0,0.083)
    # rich events for HTML
    words=[{'t0':t0,'t1':t1,'text':tx,'conf':1.0} for (t0,t1,tx) in words_t]
    cmap={}; meta=None; spk=[]
    for l in open(a.events,encoding='utf-8'):
        l=l.strip()
        if not l: continue
        d=json.loads(l)
        if d['t']=='word': cmap[round(d['t0'],3)]=d.get('conf',1.0)
        elif d['t']=='meta': meta=d
        elif d['t']=='spk_seg': spk.append(d)
    for w in words: w['conf']=cmap.get(round(w['t0'],3),1.0)
    fmts=a.fmt.split(',')
    renderers={'srt':lambda:to_srt(cues),'vtt':lambda:to_vtt(cues),
        'itt':lambda:to_itt(cues,a.lang),'fcpxml':lambda:to_fcpxml(cues,a.fps,a.lang),
        'html':lambda:to_html(words,spk,meta)}
    ext={'srt':'srt','vtt':'vtt','itt':'itt','fcpxml':'fcpxml','html':'html'}
    for f in fmts:
        if f not in renderers: print(f"unknown fmt {f}"); continue
        s=renderers[f]()
        # validate XML formats
        if f in ('itt','fcpxml'):
            try: ET.fromstring(s.split('\n',1)[1] if s.startswith('<?xml') else s)
            except ET.ParseError as e:
                # fcpxml has a DOCTYPE line; strip declaration+doctype for the check
                try: ET.fromstring(s[s.index('<fcpxml'):]) if f=='fcpxml' else (_ for _ in ()).throw(e)
                except Exception: print(f"❌ {f}: invalid XML — {e}"); sys.exit(1)
        path=f"{a.out_base}.{ext[f]}"; open(path,'w',encoding='utf-8').write(s)
        print(f"✅ {f:7s} → {path}  ({len(s)} bytes)")
    print(f"{len(cues)} cues, {len(words)} words")
