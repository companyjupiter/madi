# Sovereign Whisper — Apple Silicon (Metal) 한글 사용 가이드

Apple Silicon에서 동작하는 자체완결형 Whisper **large-v3-turbo** 음성인식기입니다.
**워드 타임스탬프**, **화자 분리(diarization, 누가-언제-무엇을)**, **언어 자동감지**,
**긴 오디오 청크 처리**를 지원합니다.

순수 **Zig + Metal/MSL + Apple 시스템 프레임워크(Metal·MPS·Accelerate)** 로 구현되어
**런타임에 Python/PyTorch/onnxruntime 의존이 전혀 없습니다.** (영문: [README.md](README.md))

> 요약: peak RSS **1.1 GB**, decode **~188 tok/s**, diarization **DER 9.67%**
> (VoxConverse dev — 상용 pyannote 3.1 SOTA ~11.2%보다 우수).
> 현재 상태 전체: [`metal/STATUS.md`](metal/STATUS.md)

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
모든 명령은 `metal/` 폴더 기준입니다.

### (1) 모델 + 토크나이저
`metal/assets/` 에 다음이 있어야 합니다:
- `model.safetensors` — Whisper large-v3-turbo 가중치 (HuggingFace에서 받기)
- 토크나이저/설정 파일: `tokenizer.json`, `generation_config.json`,
  `added_tokens.json`, `vocab.json`, `merges.txt` 등

그 다음 보조 바이너리를 생성합니다 (순수 stdlib, 의존성 없음):
```bash
cd metal/assets
python3 gen_assets.py
#  → mel_filters.bin, WHISPER_BPE.bin, suppress_tokens.bin
```

### (2) 화자 분리 모델 (diarization용, ~25MB)
Apache-2.0 wespeaker ResNet34를 받아 우리 포맷으로 변환합니다:
```bash
cd metal
bash bench/gen_diar_assets.sh
#  → assets/resnet34_diar.bin, assets/kaldi_melbank.bin
```
> diarization을 안 쓸 거면 이 단계는 건너뛰어도 전사는 됩니다(화자 분리 출력만 빠짐).

---

## 3. 빌드
```bash
cd metal
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
`metal/live_transcribe.sh` 는 마이크(또는 임의의 avfoundation 오디오 장치)를
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
> cd metal
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
cd metal
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

> **한계**: ① 5초처럼 짧은 세그먼트가 화자 전환을 가로지르면 문장 중간에 화자가
> 흔들릴 수 있습니다(세그먼트를 8~10초로 늘리면 개선). ② 무음/잡음 구간에선 Whisper가
> 환각 단어를 내고 워드 타임스탬프가 부정확할 수 있습니다(모델 자체 특성).
> 가장 정확한 최종본은 회의 종료 후 전체 WAV를 한 번에 `transcribe`로 돌리세요(4장).

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

예) 화자가 많은 회의(>6명)는 상한을 올려서:
```bash
DIAR_MAXK=10 ./out/transcribe assets/model.safetensors big_meeting.wav assets/WHISPER_BPE.bin
```
예) 한국어 강제 + 화자 3명:
```bash
WHISPER_LANG_ID=50264 ./out/transcribe assets/model.safetensors talk.wav assets/WHISPER_BPE.bin out.rttm 3
```

---

## 7. 성능 (jfk, M4 Pro 기준)
| 항목 | 초기 | 현재 |
|---|---|---|
| 인코더/청크 | 1390 ms | ~653 ms |
| 디코드 | 134 tok/s | ~188 tok/s |
| peak RSS | 4.78 GB | **1.11 GB** |
| diarization DER (VoxConverse dev) | — | **9.67%** |

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
- `metal/STATUS.md` — 현재 검증 상태(성능·RSS·DER·타임스탬프) 한눈에
- `metal/PERF_LOG.md` — 최적화 시계열 전체 기록
- `metal/bench/` — DER 벤치마크 하네스 + 화자분리 연구 문서
- `metal/PORT.md` — CUDA/PTX → Metal 포팅 노트

## 라이선스 / 출처
추론 코드: 본 프로젝트. 화자분리 가중치: wespeaker ResNet34(Apache-2.0, VoxCeleb
학습 — 상용 배포 시 데이터셋 약관 확인). Whisper 가중치: OpenAI 약관 준수.
