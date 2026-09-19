# Madiscribe — Apple Silicon (Metal) 한글 사용 가이드

Apple Silicon에서 동작하는 자체완결형 Whisper **large-v3-turbo** 음성인식기입니다.
**워드 타임스탬프**, **화자 분리(diarization, 누가-언제-무엇을)**, **언어 자동감지**,
**긴 오디오 청크 처리**, 그리고 **준실시간 라이브 회의 모드**(마이크 → 흐르는 화자별
전사, `.md`/`.srt` 저장)를 지원합니다. (라이브 사용법은 [4-b](#4-b-준실시간-회의-전사-마이크--라이브-전사)장)

순수 **Zig + Metal/MSL + Apple 시스템 프레임워크(Metal·MPS·Accelerate)** 로 구현되어
**런타임에 Python/PyTorch/onnxruntime 의존이 전혀 없습니다.** (영문: [README.md](README.md))

> 요약: peak RSS **1.05 GB**, Whisper decode **~402 tok/s**(긴 청크 ~485–496),
> diarization **DER 9.67%**
> (VoxConverse dev — 상용 pyannote 3.1 SOTA ~11.2%보다 우수).
> 현재 상태 전체: [`engine/metal/STATUS.md`](engine/metal/STATUS.md)

---

## 1. 준비물 (Requirements)
- **Apple Silicon (M1 이상)** + macOS, Xcode 커맨드라인 툴 (`xcrun metal` 사용 가능해야 함)
- [Zig](https://ziglang.org) 0.14.x
- `ffmpeg` (오디오를 16kHz 모노 WAV로 변환용)
- Python 3 — **에셋 생성 시 1회만** 필요 (추론 자체엔 불필요)

설치 예:
```bash
brew install zig ffmpeg        # Zig 0.14.x 필요 (버전 확인: zig version)
xcode-select --install         # xcrun metal 툴체인
```

---

## 2. 에셋 준비 (최초 1회)
모든 명령은 `engine/metal/` 폴더 기준입니다.

### (1) 모델 + 토크나이저
`engine/metal/assets/` 에 다음이 있어야 합니다:
- `model.safetensors` — Whisper large-v3-turbo 가중치 (HuggingFace에서 받기)
- 토크나이저/설정 파일: `tokenizer.json`, `generation_config.json`,
  `added_tokens.json`, `vocab.json`, `merges.txt` 등

그 다음 보조 바이너리를 생성합니다 (순수 stdlib, 의존성 없음):
```bash
cd engine/metal/assets
python3 gen_assets.py
#  → mel_filters.bin, WHISPER_BPE.bin, suppress_tokens.bin
```

### (2) 화자 분리 모델 (diarization용, ~25MB)
Apache-2.0 wespeaker ResNet34를 받아 우리 포맷으로 변환합니다:
```bash
cd engine/metal
bash bench/gen_diar_assets.sh
#  → assets/resnet34_diar.bin, assets/kaldi_melbank.bin
```
> diarization을 안 쓸 거면 이 단계는 건너뛰어도 전사는 됩니다(화자 분리 출력만 빠짐).

---

## 3. 빌드
```bash
cd engine/metal
bash build.sh transcribe.zig
#  → out/transcribe
```
빌드 과정: `kernels/*.metal` → `whisper.metallib` 컴파일 → ObjC 브리지 → Zig →
링크(Metal·Foundation·MPS·Accelerate). 약 5초.

---

## 4. 실행
### 오디오 변환 (16kHz 모노 필수)
```bash
ffmpeg -y -i 회의녹음.m4a -ar 16000 -ac 1 meeting.wav
```

### 기본 사용법
```bash
./out/transcribe <model.safetensors> <audio.wav> <WHISPER_BPE.bin> [out.rttm] [화자수]
```
- **4번째 인자 `out.rttm`** (선택): 화자 타임라인을 RTTM 표준 포맷으로 저장 (DER 채점용)
- **5번째 인자 `화자수`** (선택): `0` 또는 생략 → **자동 추정**, `N` → N명으로 고정

### 예시
```bash
# 전부 자동 (언어·화자수 자동감지)
./out/transcribe assets/model.safetensors meeting.wav assets/WHISPER_BPE.bin

# 화자 4명 고정 + RTTM 저장
./out/transcribe assets/model.safetensors meeting.wav assets/WHISPER_BPE.bin out.rttm 4

# 단일 화자(모놀로그/강연)는 환경변수로 1 지정
DIAR_K=1 ./out/transcribe assets/model.safetensors lecture.wav assets/WHISPER_BPE.bin
```
> 인자를 생략하면 기본값(`assets/model.safetensors`, `assets/jfk.wav`,
> `assets/WHISPER_BPE.bin`)이 쓰입니다.

---

## 4-b. 준실시간 회의 전사 (마이크 → 라이브 전사)
`engine/metal/live_transcribe.sh` 는 마이크(또는 임의의 avfoundation 오디오 장치)를
**N초 세그먼트로 굴려가며** 닫히는 즉시 전사해, 흐르는 **타임스탬프 + 화자별**
회의록을 실시간에 가깝게 출력합니다. 지연은 대략 **N + 오버랩 + 디코드(~3초)** 입니다.

순수 청크 방식의 두 가지 약점을 보완합니다:

1. **슬라이딩 윈도우 오버랩 (경계 단어 복원)** — 각 세그먼트를 이전 세그먼트의
   끝 `OVERLAP`초를 좌측 컨텍스트로 붙여 전사하고, 마지막 단어는 한 라운드
   미뤄(holdback) 다음 세그먼트가 문맥과 함께 다시 받습니다. 경계에서 잘리던
   단어가 살아납니다("company"→"country"). 시각·텍스트 이중 dedup으로 중복 제거.
2. **세그먼트 간 일관 화자 ID** — 영구 온라인 클러스터러(`online_diar`)가 세션
   전체에서 **같은 목소리 = 같은 화자 번호**를 유지합니다. 매 세그먼트 라벨이
   리셋되던 per-file 방식과 달리, 화자가 다시 등장해도 같은 ID로 붙습니다.

> 보조 도구 `diar_embed_wav`(ResNet34 임베딩)·`online_diar`(코사인 온라인 클러스터링)
> 가 필요합니다. 빌드:
> ```bash
> cd engine/metal
> bash build.sh diar_embed_wav.zig
> zig build-obj -O ReleaseFast -lc --name online_diar -femit-bin=build/online_diar.o online_diar.zig
> clang -O2 build/online_diar.o -o out/online_diar
> ```

### 오디오 장치 목록 보기
```bash
./live_transcribe.sh --list-devices
#  [2] MacBook Pro Microphone   [3] Microsoft Teams Audio  ...
```

### 실행 (플래그 CLI)
```bash
cd engine/metal
./live_transcribe.sh --help            # 전체 옵션
./live_transcribe.sh                   # 기본: 내장 마이크, 10초, 오버랩+화자 ON, 언어 자동. Ctrl-C 종료.
```

**모드 프리셋** — `--mode <이름>`은 자주 쓰는 설정 묶음입니다(개별 플래그로 덮어쓰기 가능):

| 모드 | 설정 |
|---|---|
| `ko` / `en` | 한국어/영어 강제, 화자 ON, 8초 |
| `meeting` | 다화자, 10초, 언어 자동 |
| `ko-meeting` / `en-meeting` | 위 + 한/영 강제 |
| `dictation` | 단일 화자(화자분리 끔), 텍스트만 |
| `fast` | 최저 지연(5초, 오버랩 2초, 화자분리 끔) |
| `auto` | 기본값 |

예시:
```bash
./live_transcribe.sh --mode ko-meeting          # 한국어 다화자 회의
./live_transcribe.sh -m en -s 8 --duration 60   # 영어, 8초, 60초 후 자동 종료
./live_transcribe.sh -m fast                    # 빠른 저지연 메모
./live_transcribe.sh --replay meeting.m4a -m ko # 녹음 파일을 한국어로 전사(마이크 불필요)
```

### 옵션
| 플래그 | 기본 | 의미 |
|---|---|---|
| `-m, --mode <이름>` | auto | 시나리오 프리셋(위 표) |
| `-d, --device <n>` | 2 | avfoundation 오디오 장치 인덱스 |
| `-s, --seg <초>` | 10 | 세그먼트 길이. 길수록 화자분리 정확↑·지연↑ |
| `-o, --overlap <초>` | 3 | 좌측 컨텍스트. 0이면 기능①(경계 복원) 끔 |
| `-l, --lang <id>` | auto | `ko`/`en`/`ja`/`zh`/`auto` 또는 raw 토큰. **모호 구간 오감지 방지(보험)** |
| `--diar <0\|1>` / `--no-diar` | 1 | 세그먼트 간 일관 화자 귀속(기능②) |
| `--sim <f>` | 0.40 | 새 화자 생성 코사인 임계값(낮을수록 화자 수↓) |
| `--maxk <n>` | 8 | 세션 내 최대 화자 수 |
| `--duration <초>` | — | N초 후 자동 종료(없으면 Ctrl-C까지) |
| `--replay <wav>` | — | 마이크 대신 녹음 파일 전사 |
| `--md <파일>` | — | 마크다운 회의록 동시 저장 |
| `--srt <파일>` | — | SRT 자막 동시 저장 |
| `--color <when>` / `--no-color` | auto | 화자별 콘솔 색상(auto=TTY일 때만) |
| `--speakers <맵>` | — | 화자 실명 지정 `"0=박정근,1=은지"` (콘솔·md·srt 반영) |
| `--voiceprints <폴더>` | — | **보이스프린트 등록/인식**: 이름 지정한 화자는 세션 종료 시 자동 등록 → 다음 회의부턴 **목소리만으로 자동 실명** (`VP_SIM` 임계값, 기본 0.40) |
| `--no-resident` | (상주 ON) | 상주 모델 끄고 세그먼트마다 새 프로세스(디버그용) |
| `--keep` | off | 종료 시 임시 WAV+화자 상태 보존 |
| `--model/--bpe/--bin <경로>` | assets/… | 자산·바이너리 경로 |
| `--list-devices` / `-h, --help` / `--version` | | 장치 목록 / 도움말 / 버전 |

> 모든 옵션은 동명의 환경변수(`DEVICE`, `SEG`, …)로도 줄 수 있습니다(플래그가 우선).
> `--lang`은 전용 변수라 시스템 로케일 `LANG`과 충돌하지 않습니다.

> **상주 모델(resident) — 단일 프로세스 파이프라인**: 기본적으로 `transcribe`를
> **STREAM 모드**로 한 번만 띄워, 한 프로세스 안에서 **전사 + 화자 임베딩(ResNet34) +
> 온라인 화자 클러스터링**을 모두 수행합니다. 세그먼트는 FIFO로 흘려보내 **재로드 없이**
> 처리되고, 화자 센트로이드는 메모리에 상주해 세션 내내 같은 목소리=같은 ID를 유지합니다
> (외부 `diar_embed_wav`/`online_diar` 프로세스·상태파일 불필요 — 전부 in-process).
> 언어 감지도 첫 세그먼트에서 한 번만 → 이후 고정(언어 흔들림 방지).
> ~20% 빠르고(cold-cache·짧은 세그먼트일수록 이득↑), bash 3.2 호환(coproc 대신 named
> pipe + fd 7/8). 문제 시 `--no-resident`로 세그먼트당 별도 프로세스 폴백.

> **⚠️ 마이크 권한**: 최초 실행 시 macOS가 **이 셸을 띄운 GUI 앱**(터미널/Claude 등)의
> 마이크 접근을 묻습니다. 허용해야 캡처됩니다(시스템 설정 → 개인정보 보호 및 보안 →
> 마이크). 권한이 없으면 스크립트가 힌트를 출력합니다. 토글을 바꾸면 그 앱을 재시작해야
> 적용됩니다.

> **환각 가드**: 무음/저음 구간에서 Whisper가 지어내는 단어("Oh my", "so so so")를
> **입력 RMS 기준**으로 드롭합니다(큰 발화는 RMS가 높아 항상 유지 — "아아아" 외침도
> 안전). 환경변수 `HALLU_RMS`(기본 0.020)·`VAD_THRESH`(0.010)로 조절, `HALLU_GUARD=0`으로
> 끔. 회의록은 `--md notes.md --srt notes.srt`로 동시 저장됩니다.

> **한계**: ① 5초처럼 짧은 세그먼트가 화자 전환을 가로지르면 문장 중간에 화자가
> 흔들릴 수 있습니다(세그먼트를 8~10초로 늘리면 개선). ② 환각 가드에도 강한 잡음 위의
> 오인식은 남을 수 있습니다(모델 자체 특성). 가장 정확한 최종본은 회의 종료 후 전체
> WAV를 한 번에 `transcribe`로 돌리세요(4장).

---

## 5. 출력 설명
```
[perf] chunk 1: conv 21ms | encoder 653ms | decode 26 tok 138ms (188 tok/s)
[lang] detected token 50264 (en=50259 ko=50264)          ← 언어 자동감지 결과

=== TRANSCRIPTION (1.9s, 1 chunk(s)) ===                  ← 전체 전사 텍스트
 안녕하세요. 오늘은 ...

=== WORD TIMESTAMPS ===                                   ← 단어별 시작 시각
  [0.64s]  안녕하세요.
  [1.06s]  오늘은
  ...

=== SPEAKER TIMELINE (ResNet34 embeddings, K=3) ===       ← 화자 구간
  [0.00s - 7.50s] Speaker 0
  [7.50s - 9.00s] Speaker 1
  ...

=== SPEAKER-ATTRIBUTED TRANSCRIPT ===                     ← 화자별 전사(누가 무엇을)
  [0.38s] Speaker 0: 안녕하세요. 오늘은 ...
  [7.58s] Speaker 1: 네, 그 부분은 ...
```
`out.rttm`을 지정하면 화자 타임라인이 RTTM 파일로도 저장됩니다.

---

## 6. 튜닝 (환경변수 — 재빌드 불필요)
| 변수 | 기본값 | 의미 |
|---|---|---|
| `DIAR_K` | 0(자동) | 화자 수 강제 (5번째 인자와 동일) |
| `DIAR_MAXK` | 6 | 자동추정 시 최대 클러스터 수 |
| `DIAR_SIL_TAU` | 0.10 | 이 silhouette 미만이면 단일 화자로 판정 |
| `DIAR_VAD` | 0.40 | 에너지 VAD 임계값 (중앙값 RMS 배수) |
| `WHISPER_LANG_ID` | 자동 | 언어 토큰 강제 (예: 영어 50259, 한국어 50264) |
| `ENC_BATCH` | 4(파일)/1(라이브) | 30초 청크 N개를 한 번의 배치 forward로 인코딩 — 가중치·dequant 분할상환(긴 파일 인코더 ~8%↑, 출력 byte-identical) |
| `DIAR_RECLUSTER` | 16 | 라이브: N윈도우마다 전체 임베딩 배치 재클러스터링(안정 ID 리매핑; 0=기존 온라인만) |

예) 화자가 많은 회의(>6명)는 상한을 올려서:
```bash
DIAR_MAXK=10 ./out/transcribe assets/model.safetensors big_meeting.wav assets/WHISPER_BPE.bin
```
예) 한국어 강제 + 화자 3명:
```bash
WHISPER_LANG_ID=50264 ./out/transcribe assets/model.safetensors talk.wav assets/WHISPER_BPE.bin out.rttm 3
```

---

## 7. 성능

모두 동일한 **M4 Pro**에서 측정한 wall-clock / `vmmap -summary` 실측값이며 추정치가
아닙니다. 앱에는 엔진이 두 개 들어가고 각각 따로 측정합니다.

### 전사 — `transcribe` (Sovereign Whisper)

jfk 픽스처, 2026-06-19 재측정. 정본은
[`engine/metal/STATUS.md`](engine/metal/STATUS.md), 이력은
[`engine/metal/PERF_LOG.md`](engine/metal/PERF_LOG.md).

| 항목 | 초기 | 현재 |
|---|---|---|
| conv 프런트엔드 | ~95 ms | **~15 ms** |
| 인코더 / 30초 청크 | 1390 ms | **~568 ms** · batch-4에서 **~125 ms/청크** |
| 인코더, 라이브(`AUDIO_CTX=auto`) | — | **~250–300 ms/세그먼트** |
| 디코드 | 134 tok/s | **~402 tok/s** (jfk, 26 tok) · 긴 청크 **~485–496 tok/s** |
| peak RSS | 4.78 GB | **1.05 GB** (jfk) · 1.26 GB (3분, batch-4 상주) |
| diarization DER (VoxConverse dev) | — | **9.67%** |
| 라이브(153초 한+영, 상주) | — | **~35초 (실시간 ≈4배)** |
| 정확도 | — | LibriSpeech WER **2.17%** clean / **4.19%** other · FLEURS-ko CER **4.05%** |

정확도는 `PERF_LOG` W-1/W-2b 기준입니다 — 2620 + 2939 발화, 공식 Whisper 정규화기 +
jiwer이며, 한국어 CER은 빈 hyp 0인 제품 경로 수치입니다. 공표된 large-v3가
clean 2.0 / other 3.9이므로, Q8 양자화 + 손으로 쓴 Metal 파이프라인이 레퍼런스급
품질에 도달했다는 뜻입니다.

인코더는 Metal-4 텐서 연산 한계에 도달했고(MPS 대비 1.18배), Whisper 디코드는
대역폭이 아니라 occupancy에 묶여 있습니다 — 둘 다 측정으로 닫힌 결론이라 대역폭류
최적화는 여기 적용되지 않습니다.

### 라이브 번역 — `translate-engine-{2b,4b}` (DNA3)

선택 기능이며 0.1.4 → 0.1.5 구간 측정입니다. `B`는 한 턴의 prefill 토큰 수로,
B ≈ 14–33이 라이브 캡션 대역입니다. **footprint**는 GPU 가중치, **RSS**는 프로세스
전체입니다. 정본은 `sovereignLLM/apps/metal-dna3-4b-q4km/PERF_MATRIX.md`.

| 티어 | | footprint | RSS | prefill B=14 | 디코드 |
|---|---|---:|---:|---:|---:|
| **4B** (16 GB+) | 0.1.4 | 5.5 G | 7.53 G | 153.4 ms | 62.4 tok/s |
| | **0.1.5** | **3.3 G** | **5.34 G** | **69.8 ms** | **64.7 tok/s** |
| | *미출시* | *3.20 G* | *5.23 G* | *변화 없음* | *68.5 tok/s* |
| **2B** (8 GB) | 0.1.4 | 2.6 G | 3.54 G | 59.6 ms | 125.3 tok/s |
| | **0.1.5** | **1.5 G** | **2.52 G** | **31.5 ms** | **124.1 tok/s** |
| | *미출시* | *1.54 G* | *2.49 G* | *변화 없음* | *130.8 tok/s* |

*미출시* 행은 `main`에 있고 아직 어떤 배포본에도 들어가 있지 않습니다. 0.1.5 이후
엔진 변경 두 가지이며, 둘 다 출력은 바이트 동일합니다:

1. **레이어별 V/W2 Q6_K 패킹** — 6.5비트 `ql`/`qh`로 저장하고 raw GGUF 블록 제거.
   디코드 **+3.4%**(4B) / **+2.4%**(2B), RSS −150 MB / −65 MB.
2. **FFN 융합 실행 분할(r2)** — **4B에만**. 추가 **+0.88%**, 메모리 변화 없음.
   2B에서는 win이 아니어서(+0.34%, t=0.43, 산포 2배) 기존 분할을 그대로 둡니다.

두 모델 모두 상대 결과를 가정하지 않고 각자 측정했습니다. r2 수치는 쿨다운 +
순서 교대 쌍에서 나온 값입니다 — 이 하드웨어에서는 식히지 않거나 순서를 고정하면
1% 효과보다 큰 폭으로 결과가 흔들립니다.

0.1.4 → 0.1.5: footprint **−40%**(4B) / **−42%**(2B), RSS −29%, B=14 prefill
**−54%** / **−47%**. 디코드는 사실상 그대로입니다 — 이번 이득은 첫 토큰까지의 시간과
메모리이고, 라이브 캡션에서 체감되는 건 그 둘입니다.

캡션 한 턴 전체(B=14 소스, 출력 ~30토큰): 4B **634 → 534 ms**, 2B **300 → 274 ms**.
번역 대상이 3개 언어면 prefill 절감이 3배가 됩니다.

세션 총 메모리(번역 + 전사) — 8 GB 티어를 가르는 기준:

| 머신 | 0.1.4 | 0.1.5 | 확보된 여유 |
|---|---|---|---|
| 8 GB (2B) | 3.9 G | **2.8 G** | +1.1 G |
| 16 GB (4B) | 6.8 G | **4.6 G** | +2.2 G |

이 구간에 전사 성능은 바뀌지 않았습니다. 위 전사 표는 기준선이지 결과가 아닙니다.

---

## 7-b. 버전 이력

릴리스 빌드는 S3 `stable` 채널에 게시되고 CloudFront로 배포됩니다. 앱 내 업데이터는
`channels/stable/latest.json`을 읽습니다. 릴리스 절차와 git 태그 규칙은
[docs/RELEASE.md](docs/RELEASE.md)에 있습니다.

게시된 버전(S3 `releases/index.json`): 아래 0.1.0 → 0.1.5 다음으로 **0.1.6**(2026-07-31, Sparkle
자동 업데이트), **0.1.7**(2026-08-05, 번역 표시 안정성 — NE 실측 기반 안정 접두 정책), **0.1.8**
(2026-08-10, 문장 핸드오프 무소거화 + 안정성 원장 파일), **0.1.9**(2026-08-11, 표면 교정 리바인드),
**0.2.0**(2026-08-30, 한 번 판정하는 경계 원장 — 세션 중 재클러스터가 라이브 행을 무너뜨리지 않음),
**0.3.0**(2026-08-31, 요약 템플릿 + 실시간 요약 탭), **0.3.1**(2026-09-02, 엔진 헤드룸 배치: 시드
프리필·프리뷰/인터림 강제 접두·문맥 예시), **0.3.7**(2026-09-03, 라이브 프로파일링 P0–P4: 메인
스레드 포화·번역 백로그·줄 수 비례 CPU·STT 루프 가드), 그리고 **0.3.21**(2026-09-08, `v0.3.21`,
빌드 742) — 현재 `stable`: 언어 게이트 P5/P6과 한글 전용 글로서리 프롬프트(P6-2), 메모리 M1–M3, 줄
합침 L1/L2, 번역 상한 T7–T9, 디버그 모드 D1, 화자 번호 지연 S1, 턴 묶음 U1, 이음매 화면 규칙
X1/X2/X4, 조용한 입력의 전체 인코더 문맥(A1), 입력 레벨 표시. 0.3.8 → 0.3.20은 그 라운드들의 로컬
검증 빌드(ad-hoc 서명, PERF_LOG 항목당 하나)로 게시되지 않았다.

| 버전 | 게시일 | 태그 | 주요 내용 |
|---|---|---|---|
| **0.1.5** | 2026-07-26 | `v0.1.5` | 화자 번호 안정화 — 클러스터러가 재번호를 매겨도 주화자는 *Speaker 1*을 유지. 라벨 미결정 중에는 `화자분리중…` 표시, 300초 후 잠정 번호로 확정 (#229). DNA3 번역 엔진 0.1.5: footprint −40%, B=14 prefill −54%. 번역 티어 메모리 상수 교정 (#228). 턴별 DNA 워치독 + 엔진 재시작 (#227). 사이드 패널 재설계 (#220), 입력 선택기 드롭업 수정 (#217). |
| **0.1.4** | 2026-07-22 | `v0.1.4` | 한국어 화자분리 견고성 (#226), 카운트다운 시작 승인 수정 (#225), 첫 실행 모델 온보딩 (#224), 시스템 오디오 권한 UX (#223). |
| 0.1.3 | 2026-07-22 | — | 0.1.4와 **같은 소스**(`450e527`)를 같은 날 재빌드·재게시한 것. 별도 태그 없음 — 이미 `v0.1.4`가 그 트리를 가리키므로 태그를 둘 붙이면 `git describe`만 모호해집니다. |
| **0.1.2** | 2026-07-20 | `v0.1.2` | M1 / 8 GB에서 DNA3-2B 티어 라이브 번역 (#221)과 8 GB 가이드 (#222); 운영자·에이전트 간 재현 가능한 로컬 S3 릴리스 (#219). |
| **0.1.1** | 2026-07-20 | `v0.1.1` | 라이브 화자분리 무음 구간 오탄생 수정 (#218); GitHub 배포에 의존하지 않는 업데이트 (#215). |
| **0.1.0** | 2026-07-19 | `v0.1.0` | 첫 공식 정식 릴리스. 화자분리 ON/OFF 토글 (#216), S3 릴리스 채널. |

---

## 8. 문제 해결 (Troubleshooting)
- **`xcrun: error` / metallib 실패** → Xcode 툴 설치(`xcode-select --install`), Apple Silicon Mac인지 확인.
- **에셋 없음 오류(MissingTensor 등)** → 2장(에셋 준비)을 먼저 수행했는지 확인.
- **화자 분리가 이상함** → `화자 수`를 직접 지정하거나 `DIAR_MAXK` 조정. 깨끗한
  근접 마이크 녹음일수록 정확합니다(원거리/잡음 환경은 DER가 높아짐).
- **전사에 같은 말 반복("Q. Q. Q." 등)** → 조용하거나 어려운 구간의 Whisper
  repeat-loop 환각(알려진 한계, 가드 미구현).
- **메모리/속도** → diarization은 CPU(멀티스레드)에서 도므로 긴 파일은 시간이 더 걸립니다.

---

## 9. 더 보기
- `engine/metal/live_transcribe.sh` — 준실시간 라이브 회의 러너(마이크·오버랩·상주·색상·md/srt)
- `engine/metal/merge_seg.awk` — 워드 타임스탬프 ↔ 화자 라벨 머지(오버랩 dedup·화자 캐리오버)
- `engine/metal/online_diar.zig`·`diar_embed_wav.zig` — 독립 diar 도구(`--no-resident` 폴백용)
- `engine/metal/testdata/` — 라이브 파이프라인 회귀 픽스처(한+영) + `check.sh`
- `engine/metal/STATUS.md` — 현재 검증 상태(성능·RSS·DER·타임스탬프) 한눈에
- `engine/metal/PERF_LOG.md` — 최적화 시계열 전체 기록
- `engine/metal/bench/` — DER 벤치마크 하네스 + 화자분리 연구 문서
- `engine/metal/PORT.md` — CUDA/PTX → Metal 포팅 노트

## 10. 자산 목록 — 무엇이 있고, 어디에 있고, 어떻게 검증됐나

아래는 모두 이 저장소에 실재하며(번역 엔진은 [`engine/prebuilt/`](engine/prebuilt/README.md)의
사전 빌드 바이너리 — 소스는 비공개 자매 저장소 `sovereignLLM`), **측정으로
확인된 것만 남긴** 결과다 — 이 프로젝트의 규칙. 반증된 레버도 같은 원장에 기록한다.
행마다 정본 문서를 적었고, 행과 정본이 다르면 정본이 맞다.

### 런타임 엔진 (`Madi.app`에 동봉)

| 자산 | 무엇 | 위치 | 검증 |
|---|---|---|---|
| **Sovereign Whisper** `transcribe` | Whisper large-v3-turbo Q8, 순수 Zig + Metal. 파일 모드와 상주 **STREAM** 모드(5 s 창 + 오버랩, 단어 타임스탬프, `PREVIEW` 레인, `%%FP` 강제 접두, `EVENTS_FILE` JSONL 계약) | `engine/metal/transcribe.zig`, `encoder.zig`, `decoder.zig`, `mel.zig`, `kernels/` | LibriSpeech WER 2.17 / 4.19 %, FLEURS-ko CER 4.05 %, jfk 디코드 ~402 tok/s, 최대 RSS 1.05 GB — [`engine/metal/STATUS.md`](engine/metal/STATUS.md) |
| **화자분리** | WeSpeaker ResNet34 임베딩 + 온라인 클러스터링(주기적 재클러스터 `DIAR_RECLUSTER`), 겹침 검출(pyannote seg-3.0), Silero VAD 게이트, 화자 수 고정 + 미확인 버킷, ON/OFF 토글 | `diar_resnet.zig`, `online_diar.zig`, `osd_pyannote.zig` | VoxConverse dev DER 9.67 %; 라이브 DER/UX 게이트는 `engine/metal/bench/` — [`docs/DIAR_EVAL.md`](docs/DIAR_EVAL.md) |
| **DNA3.0-4B / 2B 번역 엔진** | 온디바이스 LLM(번역·요약·Q&A·제목)용 GGUF Q4_K_M 러너. 턴 REPL: `%%TRN`(턴 + 예시 쌍), `%%PFX`(접두 슬롯), ` %%FP `(강제 접두), ` %%MAX n`(턴당 상한); 임베딩 창만 남기는 가중치 매핑 해제(4B RSS 5.4 → 2.5 GB) | `sovereignLLM/apps/metal-dna3-{4b,2b}-q4km/main.zig`(정본 `PERF_MATRIX.md`) | 프리필 B=14 69.8 ms / 디코드 64.7 tok/s(4B); Whisper 포함 8/16 GB 티어 메모리 예산 ≈ 4.05 GB — PERF_LOG M1 |
| DNA3.0-9B 티어(24 GB+) | 엔진 측 완료(턴 프로토콜 6/6, mmap 해제, 컨텍스트 8192 +233 MB). 앱 배선과 GGUF 호스팅은 **2026-09-07부로 보류** | `sovereignLLM/apps/metal-dna3-9b-q4km/` | — |

출시된 엔진 레버(각각 PERF_LOG에 측정치가 있다): 글로서리 시드의 디코더 시퀀스 프리필(S1,
−155 ms/패스) · 프리뷰 강제 접두(S2, 프리뷰 디코드 −38 %) · 인터림 강제 접두(T1, −23 %) ·
직전 (원문 ⇒ 번역) 쌍을 프롬프트 예시로(T5) · 글로서리 → 디코더 바이어싱, 측정된 언어에만
(S4, P6) · 폭주 환각 대비 partial 동결(`PARTIAL_MAX_TOK`) · 배치 인코더(`ENC_BATCH`),
F16 인코더 캐시, `AUDIO_CTX=auto`(첫 텍스트 ~1.8 s) · 누수 없는 프리뷰 레인(M2 +23 MB/분,
M3 +2.3 MB/분 수정; 회귀용 `LEAK_CHECK` DebugAllocator 빌드).
반증·기록된 것: 이전 텍스트 조건화(S3), 디코드 점유율 레버(S5), int8 프리필, 엔진 측
화자 id 상한(D1), 타사 파인튜닝 가중치 드롭인, 가중치 매핑 madvise. 엔진 센트로이드 병합은
아직 후보.

### macOS 앱 (`apps/macos/Sovereign`, SwiftUI; 헤드리스 코어는 `Package.swift`)

| 자산 | 하는 일 | 정본 |
|---|---|---|
| 라이브 파이프라인: `WordMerger` → `TranscriptStore` → `TranscriptView` | 오버랩 중복 제거 + 꼬리 단어 보류를 **화면도 같은 이음매 규칙으로**(X1), 이음매 중복·창 꼬리 그루터기 가드(L2, X2); **한 번 판정하는 경계 원장**(P15)은 확정 단어 사이만 기록, 라벨 교정 뒤 같은 화자 이웃 줄 합침(L1), 한 단어 턴 머리는 다음 화자로(X4); 행 = 문장, 상세 보기는 같은 화자의 연속 행을 턴으로 묶음(U1) | [`PERF_LOG.md`](PERF_LOG.md) P15 · L1 · L2 · X1 |
| 화자 표시 | id 발화 10 s 이상일 때만 번호, 그 전엔 `화자분리중…`(S1); 재클러스터에도 안정된 번호; 성문 자동 이름; 정지 시 AI 화자/언어 교정 | PERF_LOG S1 · [`docs/DIAR_EVAL.md`](docs/DIAR_EVAL.md) |
| 번역 레인: `TranslateEngine`, `TranslationTurnQueue`, `DNAEngineBroker` | 확정 줄 우선 큐, 조각 줄 병합, 2순위 언어 shed + 정지 시 채움, stale 유지 표시, 폭주 상한(T7: 엔진 `%%MAX` + 앱 절단 + 예시 오염 가드), 개정판의 공통 접두를 자르지 않는 에코 제거기(T8), 패널로 토큰 스트리밍 없음(T9), 턴당 워치독 종료 + 재기동 | [`docs/LIVE_TRANSLATE.md`](docs/LIVE_TRANSLATE.md) · [`docs/TRANSLATE_DISPLAY_STABILITY.md`](docs/TRANSLATE_DISPLAY_STABILITY.md)(NE < 0.2 안정 접두 정책; 라이브 패널 NE 0.24–0.27) |
| 회의 인텔리전스 | 요약 템플릿(회의/강의/인터뷰, 스파인 1), 롤링 실시간 요약(구현됨, 현재 배선 해제), Q&A, 제목, 액션 아이템 | [`docs/MEETING_INTELLIGENCE.md`](docs/MEETING_INTELLIGENCE.md) · [`docs/SUMMARY_TEMPLATES.md`](docs/SUMMARY_TEMPLATES.md) · [`docs/LIVE_SUMMARY.md`](docs/LIVE_SUMMARY.md) |
| 캡처 | 마이크(장치 선택), ScreenCaptureKit **시스템 오디오**(Teams / Zoom / YouTube), 둘 다; 캡처 준비에 걸린 카운트다운; 무음 경고 | [`docs/SYSTEM_AUDIO.md`](docs/SYSTEM_AUDIO.md) · [`apps/macos/VERIFY_CAPTURE.md`](apps/macos/VERIFY_CAPTURE.md) |
| 디버그 모드(D1) | 설정 → 진단 또는 `MADI_DEBUG=1`: 세션당 번들 하나 `~/Library/Application Support/Madi/debug/<stamp>/` — 엔진 바이트 그대로(`env.txt`, `stdin.log`, `wav/`, `stdout.log`, 이벤트 사본), `store.jsonl`(boundary / merge / join / ledger-flip / spk), `translate.jsonl`(turn / result / shed / wedge / relaunch), `watchdog.jsonl`, `mem.jsonl`, `session.json` | [`docs/DEBUG_MODE.md`](docs/DEBUG_MODE.md) |
| 제품 표면 | KO / EN / JA UI, 4개 국어 매뉴얼(`docs/manual/`), 받아쓰기, 편집기·리더 기능, `.md` / `.srt` / JSON 내보내기, 첫 실행 모델 온보딩(SHA-256 검증), S3 채널 Sparkle 자동 업데이트, 베타 만료 래치, Figma 디자인 토큰 동기화 | [`apps/macos/DESIGN.md`](apps/macos/DESIGN.md) · [`docs/EDITOR_FEATURES.md`](docs/EDITOR_FEATURES.md) · [`design/README.md`](design/README.md) |

### 측정·검증 도구

| 도구 | 용도 | 실행 |
|---|---|---|
| `swift test`(SovereignCore) | 머저·스토어 원장·번역 큐·shed·폭주·stale 유지·번호·디버그 로그 위의 헤드리스 테스트 649건 | `cd apps/macos && swift test` |
| 캡처 재생 게이트 | 세션의 `stdout.log`를 실제 Decoder → TranscriptStore로 바이트 그대로 재생해 행 수 / 미설명 끊김 / 이음매 중복 행 / 중복 단어 / 겹침 행 / 턴 머리 행 / 번호를 레버 off/on별로 출력 | `MADI_CAPTURE_STDOUT=<bundle>/stdout.log swift test --filter CaptureFragmentationGateTests` |
| 이벤트 게이트 | 엔진 `EVENTS_FILE` JSONL로 같은 측정(`MADI_EVENTS_JSONL=…`); X1 같은 화면 상태 결함은 못 본다 | 같은 테스트 클래스 |
| `bench/live_capture/` | `tee_transcribe.py`가 실제 앱 → 엔진 스트림을 기록, `replay_capture.py` / `replay_faithful.py`가 오프라인 재생(디버그 번들에도 동작) | [`engine/metal/bench/live_capture/README.md`](engine/metal/bench/live_capture/README.md) |
| `longwatch.sh` | 10 s 수집기: 프로세스별 CPU / RSS / 스레드, GPU 사용률, 압축기, 5분마다 메인 스레드 `sample`; PERF_LOG의 모든 라이브 CPU·메모리 수치의 출처 | `engine/metal/bench/wer_runs/prof/longwatch.sh`(`LW_OUT`, `LW_MT`) |
| `t1_harness.py` | 기록된 턴으로 번역 엔진을 턴 프로토콜대로 구동(번들의 `translate.jsonl`이 그대로 입력) | `engine/metal/bench/wer_runs/t1_harness.py`(`ENGINE`, `MODEL`) |
| 품질 벤치 | `wer_bench.py`(LibriSpeech / FLEURS, 공식 정규화 + jiwer), DER 하네스(AMI, VoxConverse), `ko_diar_gate.py`, `live_ux_gate.py`, `preview_lane_gate.py`, VAD 캠페인, 엔진 A/B([`docs/ENGINE_EVAL.md`](docs/ENGINE_EVAL.md): FLEURS-ko CER Qwen3-ASR-1.7B 4.60 % vs Whisper turbo 5.63 %, 8 GB 티어에는 미채택) | `engine/metal/bench/`([README](engine/metal/bench/README.md)) |
| 누수 변형 빌드 | DebugAllocator(`LEAK_CHECK`, ReleaseSafe/Debug)로 빌드한 `transcribe`가 종료 시 누수를 보고; 장기 실행 점검용 합성 프리뷰/seg 스트림 | `engine/metal/build.sh transcribe.zig`, PERF_LOG M2/M3 |
| Quark 트리 | 엔진·앱의 심볼 단위 토폴로지(AI 탐색·커밋 후 신선도): `sovereign_metal_whisper`, `sovereign_whisper_app`, `sovereign_metal_dna3_{2b,4b,9b}` | `~/antigravity/quark/q.sh regen configs/<cfg>.mjs` |
| 원장 | [`PERF_LOG.md`](PERF_LOG.md) — 날짜 붙은 42개 항목(2026-07-05 → 2026-09-07), 수치·채택·반증; [`engine/metal/PERF_LOG.md`](engine/metal/PERF_LOG.md) — 엔진 이력; [`docs/BACKLOG.md`](docs/BACKLOG.md) — 고려만 한 것 | — |

### 릴리스 파이프라인

`apps/macos/scripts/madi_release.sh build|upload|publish <version>` 하나가 진입점(`skills/madi-release`
스킬이 이걸 구동): `make_app.sh`(명시적 소스 목록) → `verify_release_bundle.sh` → DMG → Developer ID
서명 + 공증 + 스테이플(인증서가 있을 때; 없으면 ad-hoc) → 불변 S3 업로드 → 채널 게시. 업데이터는
CloudFront로 `channels/<channel>/latest.json`과 `appcast.xml`을 읽고 크기 + SHA-256 + URL을 검증하며,
`releases/index.json`이 게시 버전의 정본이다. 스모크 체크리스트와 태그 규칙은
[`docs/RELEASE.md`](docs/RELEASE.md).

### 부속 유틸리티

`tools/`(이벤트 계약 위의 자막·회의록·SRT 방송 — [`docs/EVENTS.md`](docs/EVENTS.md)), `web/`(이벤트
대시보드 + 브리지 서버, 픽스처), `design/`(Figma ↔ 앱 토큰 동기화).

---

## 라이선스 / 출처
추론 코드는 본 프로젝트의 독자 구현입니다. 다섯 가지 서드파티 모델을 재사용하고 앱 업데이트에
Sparkle 프레임워크를 포함하며,
요구되는 고지를 코드·배포물에 모두 유지합니다:

- **OpenAI Whisper** large-v3-turbo — **MIT License**, © 2022 OpenAI (전사).
  MIT도 저작권+허가 고지 유지가 **필수**입니다(면제 아님).
- **WeSpeaker** ResNet34 — 툴킷·아키텍처는 **Apache License 2.0**, VoxCeleb으로
  학습된 **가중치는 CC BY 4.0** (WeSpeaker가 사전학습 모델은 학습 데이터셋의
  라이선스를 따른다고 명시). © WeSpeaker authors (화자분리). 둘 다 상업적 사용을
  허용하며, 귀속 표시와 변경 사실 명시가 필요하고 Apache-2.0은 NOTICE 동봉도
  요구합니다.
- **Silero VAD** — **MIT License**, © 2020-present Silero Team (발화 구간 판정).
- **pyannote** segmentation-3.0 — **MIT License**, © 2020 CNRS (겹침 구간 검출).
- **DNA3.0-2B / 4B** — **Apache License 2.0**, © Dnotitia Inc.; 베이스 모델
  Qwen3.5 © Alibaba Cloud (번역·요약·질의응답 — 번들이 아니라 필요 시 다운로드).
- **Sparkle** — **MIT License**, © Andy Matuschak 및 Sparkle 기여자 (앱 내 업데이트,
  `Sparkle.framework`를 수정 없이 포함; Sparkle에 든 외부 코드의 라이선스도 함께 고지).

전체 고지·라이선스 전문은 [`NOTICE`](NOTICE)·[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md),
소스 헤더(`engine/metal/transcribe.zig`·`engine/metal/diar_resnet.zig`)에도 동일 고지가 있습니다.
