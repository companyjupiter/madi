#!/usr/bin/env python3
# Generate a controlled clean 4-speaker clip (macOS `say`) + ground-truth RTTM,
# for qualitative/objective diarization demo. → bench/demo4.wav, demo4.ref.rttm
import subprocess, os, wave
os.makedirs("/tmp/say", exist_ok=True)
turns = [
 ("Alex","Good morning everyone, let's start the design review for the new service."),
 ("Samantha","Thanks. I looked at the proposal and I have a few concerns about latency."),
 ("Daniel","Right, the cross region calls could add significant overhead in my view."),
 ("Karen","I agree, but we could cache aggressively to reduce the round trips."),
 ("Alex","Good point. Let's quantify the expected traffic before deciding."),
 ("Samantha","I can run a load test this afternoon and share the numbers tomorrow."),
 ("Daniel","Please also include the failure scenarios when a region goes down."),
 ("Karen","And we should document the cache invalidation strategy clearly."),
 ("Alex","Agreed. Let's reconvene on Thursday with the data and a final plan."),
 ("Samantha","Sounds good to me, I will send a calendar invite right after this."),
 ("Daniel","Works for me, thanks everyone for the thorough discussion today."),
 ("Karen","Great, talk to you all on Thursday then, have a good day."),
]
files=[]; rttm=[]; t=0.0
for i,(v,txt) in enumerate(turns):
    a,w=f"/tmp/say/{i}.aiff",f"/tmp/say/{i}.wav"
    subprocess.run(["say","-v",v,"-o",a,txt],check=True)
    subprocess.run(["ffmpeg","-y","-i",a,"-ar","16000","-ac","1",w],capture_output=True,check=True)
    dur=wave.open(w).getnframes()/16000
    rttm.append(f"SPEAKER demo4 1 {t:.3f} {dur:.3f} <NA> <NA> {v} <NA> <NA>"); t+=dur; files.append(w)
open("/tmp/say/list.txt","w").write("".join(f"file '{w}'\n" for w in files))
subprocess.run(["ffmpeg","-y","-f","concat","-safe","0","-i","/tmp/say/list.txt","-ar","16000","-ac","1","bench/demo4.wav"],capture_output=True,check=True)
open("bench/demo4.ref.rttm","w").write("\n".join(rttm)+"\n")
print(f"demo4.wav {t:.1f}s, 4 speakers / {len(turns)} turns")
