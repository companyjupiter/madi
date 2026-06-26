#!/usr/bin/env python3
# AMI far-field validation: turn the n=1 (ES2004a) far-field finding into n>=6.
# Fetches Array1-01 (far-field mic) audio + manual word annotations for several
# meetings, builds full-meeting RTTM, sweeps VAD_PROB DER. Tests whether the
# miss-dominated "looser gate wins on far-field" slope reproduces off ES2004a.
#   python3 bench/ami_validate.py
import os, glob, json, subprocess, sys, time, zipfile, urllib.request, xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
M = os.path.dirname(HERE)
RUNS = os.path.join(HERE, "runs")
AMI = os.path.join(RUNS, "ami")
os.makedirs(AMI, exist_ok=True)
MDEVAL = os.path.join(HERE, "md-eval.pl")
TR = os.path.join(M, "out/transcribe")
MODEL = os.path.join(M, "assets/model.safetensors")
BPE = os.path.join(M, "assets/WHISPER_BPE.bin")
RESULTS = os.path.join(RUNS, "ami_validate.jsonl")

MEETINGS = os.environ.get("AMI_MEETINGS", "ES2004b,ES2004c,ES2004d,IS1000a,TS3003a").split(",")
PROBS = [float(x) for x in os.environ.get("VAD_PROBS", "0.2,0.35,0.5,0.65,0.8,0.9").split(",")]
ANN_URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"
MIRROR = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{m}/audio/{m}.Array1-01.wav"

def log(*a): print("[ami]", *a, flush=True)

def fetch(url, dst):
    if os.path.exists(dst) and os.path.getsize(dst) > 1000:
        return
    log("fetch", url)
    subprocess.run(["curl", "-sL", "--fail", "-o", dst, url], check=True)

# 1) annotations (words XML)
ann_zip = os.path.join(AMI, "ami_manual.zip")
words_dir = os.path.join(AMI, "ami_annotations", "words")
if not glob.glob(os.path.join(words_dir, "*.words.xml")):
    fetch(ANN_URL, ann_zip)
    with zipfile.ZipFile(ann_zip) as z:
        z.extractall(os.path.join(AMI, "ami_annotations"))
    log("annotations extracted")
# words may land in words/ at the root of the zip
if not glob.glob(os.path.join(words_dir, "*.words.xml")):
    alt = glob.glob(os.path.join(AMI, "ami_annotations", "**", "*.words.xml"), recursive=True)
    if alt:
        words_dir = os.path.dirname(alt[0])
log("words dir:", words_dir, "files:", len(glob.glob(os.path.join(words_dir, "*.words.xml"))))

def build_rttm(meeting):
    xmls = sorted(glob.glob(os.path.join(words_dir, f"{meeting}.*.words.xml")))
    out = os.path.join(AMI, f"{meeting}.rttm")
    lines = []
    for xp in xmls:
        spk = os.path.basename(xp).split(".")[1]  # ES2004b.A.words.xml → A
        segs = []
        for w in ET.parse(xp).getroot().findall(".//w"):
            st, et = w.get("starttime"), w.get("endtime")
            if st and et:
                try: segs.append((float(st), float(et)))
                except ValueError: pass
        if not segs: continue
        segs.sort()
        merged = [list(segs[0])]
        for s, e in segs[1:]:
            if s - merged[-1][1] < 0.5: merged[-1][1] = e
            else: merged.append([s, e])
        for s, e in merged:
            lines.append(f"SPEAKER {meeting} 1 {s:.3f} {e-s:.3f} <NA> <NA> {spk} <NA> <NA>")
    lines.sort(key=lambda L: float(L.split()[3]))
    open(out, "w").write("\n".join(lines) + "\n")
    nspk = len(xmls)
    return out, nspk

def to16k(src, dst):
    if os.path.exists(dst) and os.path.getsize(dst) > 1000: return
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-ar", "16000",
                    "-ac", "1", "-c:a", "pcm_s16le", dst], check=True)

def der(ref, sysr):
    out = subprocess.run(["perl", MDEVAL, "-c", "0.25", "-r", ref, "-s", sysr],
                         capture_output=True, text=True).stdout
    for L in out.splitlines():
        if "OVERALL SPEAKER DIARIZATION ERROR" in L:
            return float(L.split("=")[1].split()[0])
    return None

done = set()
if os.path.exists(RESULTS):
    for l in open(RESULTS):
        if l.strip(): d = json.loads(l); done.add((d["prob"], d["meeting"]))

with open(RESULTS, "a") as out:
    for m in MEETINGS:
        try:
            raw = os.path.join(AMI, f"{m}.Array1-01.raw.wav")
            fetch(MIRROR.format(m=m), raw)
            wav = os.path.join(AMI, f"{m}.wav")
            to16k(raw, wav)
            ref, nspk = build_rttm(m)
            log(f"{m}: nspk={nspk}, audio ready")
        except Exception as e:
            log(f"{m}: SKIP ({e})"); continue
        for prob in PROBS:
            if (prob, m) in done: continue
            sysr = os.path.join(AMI, f"{m}_p{prob}.rttm")
            env = {**os.environ, "DIAR_ONLY": "1", "VAD_PROB": str(prob)}
            subprocess.run([TR, MODEL, wav, BPE, sysr], env=env, capture_output=True)
            d = der(ref, sysr)
            rec = {"prob": prob, "meeting": m, "nspk_ref": nspk, "der": d}
            out.write(json.dumps(rec) + "\n"); out.flush()
            log(f"  {m} p={prob} der={d}")
log("AMI_VALIDATE_DONE →", RESULTS)
