# Multilingual + timestamp + long-audio verification

Test asset: a 7m42s Korean DevOps Q&A (2-person dialogue), resampled to 16 kHz
mono. Personal recording — not committed (git-ignored). Reproduce by pointing
`transcribe` at any 16 kHz mono WAV.

```bash
ffmpeg -y -i input.wav -ar 16000 -ac 1 -c:a pcm_s16le bench/clip.wav
./out/transcribe assets/model.safetensors bench/clip.wav assets/WHISPER_BPE.bin /tmp/out.rttm 2
```

## Results (2026-06-08)

**Language auto-detection** ✅ — detected token 50264 (`<|ko|>`) from the
SOT-position logits (arg-max over the language range 50259..50358). jfk still
auto-detects 50259 (`<|en|>`). Override available via `WHISPER_LANG_ID`.

**Korean transcription** ✅ — fluent and accurate across all 16 chunks. Sample:
> 안녕하세요. 오늘은 당신이 보내주신 유튜브 채널 데브아트, 데바츠의 데브옵스 Q&A
> 영상을 좀 깊게 파보[려]고 합니다. 아, 네. 그 강연 후에 질문 답변한 영상이죠? …

Last chunk (@450s) still coherent — no long-audio degradation:
> 개발과 운영 업무를 자동화할 텐데 … 어떤 대체 불가능한 가치를 만들어내는 데 더
> 집중해야 할까요? 한 번쯤 깊이 고민해보시면 좋을 것 같습니다.

Minor: one ASR slip ("파보여고" vs "파보려고"). No objective WER (no reference).

**Word timestamps** ✅ — monotonic and well-aligned (cross-attention argmax +
median-3, global chunk offset):
```
[0.48s] 안녕하세요.  [0.88s] 오늘은  [1.04s] 당신이  [1.52s] 보내주신
[2.26s] 유튜브  [2.54s] 채널  [3.48s] 데브아트,  [5.46s] 데브옵스  [6.16s] Q&A …
```

**Diarization** ✅ (qualitative) — K=2 default; timeline alternates Speaker 0/1
matching the 2-person Q&A turn structure (0–1.5 S0, 1.5–4.5 S1, 4.5–12 S0, …).
No ground truth for this clip; objective DER is on AMI (see README → 65% K=2).

**Performance** — 462s audio processed in **36.5s (~12.7× real-time)**;
encoder ~656 ms/chunk, decode 212–237 tok/s (Korean). Comfortable for live use.

## Next Win candidates (recorded for follow-up)
1. **4+ speaker diarization on clean audio** — needs a dedicated speaker
   embedding model (ECAPA/x-vector); mel features top out at ~2 reliable
   speakers (AMI 65% @ K=2, see README). This is the headline diarization Win.
2. **Objective multilingual WER** — add a labeled clip (e.g. Korean
   read-speech with a reference) to measure CER/WER, not just eyeball.
3. **Timestamp accuracy metric** — score word boundaries against forced
   alignment (DTW/MFA) instead of qualitative inspection.
