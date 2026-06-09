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
