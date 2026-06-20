# Sovereign Whisper — macOS 제품 설계 (DMG 배포)

> 목표: 검증된 `metal/` 엔진을 **한 줄도 수정하지 않고** 감싸는 독립 윈도우
> macOS 앱(M1+)으로 만들어 Developer ID 서명 + 노터라이즈된 `.dmg`로 배포한다.
> 결정사항: **AVAudioEngine 네이티브 캡처 / 독립 윈도우 앱 / 첫 실행 모델 다운로더.**

---

## 0. 설계 원칙

1. **엔진 불가침.** `metal/out/transcribe`는 30여 건 referee 검증을 통과한 자산이다.
   앱은 이 바이너리를 **자식 프로세스로 spawn**하고 stdin/stdout 계약으로만
   대화한다. 엔진을 라이브러리로 링크하지 않는다(프로세스 격리 = 크래시 격리 +
   엔진 재빌드와 앱 빌드 독립).
2. **외부 실행 의존 0.** 기존 `live_transcribe.sh`는 마이크 캡처에 `ffmpeg`를
   썼다. 앱은 이를 **AVAudioEngine**로 대체 — ffmpeg 번들/GPL/별도서명이 통째로
   사라지고, 마이크 권한이 OS 표준 UX가 된다.
3. **한 바이너리로 구·신형 커버.** Metal-4 커널은 `getFunction` 실패 시 MPS로
   자동 폴백하므로 `LSMinimumSystemVersion`을 낮춰도 구형 OS에서 느린 경로로
   동작한다. arm64-only(M1+).

---

## 1. 시스템 구조

```
┌─────────────────────────────────────────────────────────────┐
│  Sovereign.app  (SwiftUI, arm64, Hardened Runtime)           │
│                                                              │
│  ┌──────────────┐   16k mono WAV    ┌────────────────────┐   │
│  │ AudioCapture │ ───seg 파일 경로──▶│  EngineProcess     │   │
│  │ (AVAudio-    │                   │  spawn out/transcribe   │
│  │  Engine)     │ ◀──권한/레벨미터──│  STREAM=1 DIAR=1    │   │
│  └──────────────┘                   │  stdin:  "<off> <wav>"  │
│         ▲                           │  stdout: SPK/W/SPKFIX…  │
│         │ 마이크                    └─────────┬──────────┘   │
│   ┌─────┴─────┐                               │ 파싱         │
│   │ 사용자    │                     ┌─────────▼──────────┐   │
│   └───────────┘                     │  EngineProtocol    │   │
│                                     │  (line → 이벤트)   │   │
│   ┌───────────────┐                 └─────────┬──────────┘   │
│   │ TranscriptView│ ◀───@Published──┌─────────▼──────────┐   │
│   │ SettingsView  │                 │  TranscriptStore   │   │
│   └───────────────┘                 │  (live 라인/relabel/   │
│                                     │   overlap 마커)     │   │
│   ┌───────────────┐                 └─────────┬──────────┘   │
│   │ ModelDownloader│                          │ export       │
│   │ (첫 실행)      │                 ┌─────────▼──────────┐   │
│   └───────────────┘                 │  Exporters (md/srt)│   │
│                                     └────────────────────┘   │
│                                                              │
│  Bundle: Contents/MacOS/{Sovereign, transcribe, whisper.metallib}
│          Contents/Resources/assets-small/{pyannote,silero,resnet,bpe,…}
│  첫 실행: model.safetensors → ~/Library/Application Support/Sovereign/
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 엔진 I/O 계약 (코드에서 확인된 정본)

`metal/transcribe.zig` STREAM 모드 (`STREAM=1` 환경변수로 진입):

### stdin (앱 → 엔진)
```
<global_offset_seconds> <wav_path>\n   # 세그먼트가 닫힐 때마다 한 줄
FLUSH\n                                # 세션 종료 시 — relabel + overlap 방출
```

### stdout (엔진 → 앱)
| 라인 | 의미 | 앱 처리 |
|---|---|---|
| `[stream] ready (...)` | 모델 상주 완료 | 캡처 시작 게이트 해제 |
| `=== WORD TIMESTAMPS ===` | 단어 섹션 시작 | 이후 `[t0s-t1s] word` 누적 |
| `[<t0>s-<t1>s] <word>` | 단어 + 전역 타임스탬프 | live 라인 빌드 |
| `SPK <gt> <id> [dur]` | 스트리밍 화자 라벨(1.5s 윈도) | live 화자 배정 |
| `SPKFIX <gt> <id> [dur]` | FLUSH: 재클러스터 보정 라벨 | 최종 transcript relabel |
| `SPKOV <gt> <id> [dur]` | FLUSH: 중첩 2번째 화자 | "⟨+Speaker N 겹침⟩" 마커 |
| `<<FLUSH_END>>` | 마감 완료 | export 트리거 |

> 주의: 엔진은 단어 타임스탬프를 **전역 시간으로 이미 글로벌화**해서 내보낸다
> (offset 더할 필요 없음). 스트리밍 라벨(SPK)은 즉시, 보정 라벨(SPKFIX/SPKOV)은
> FLUSH 때만. 따라서 앱은 두 단계 렌더링: ① live(SPK 기준) → ② final(SPKFIX 기준).

### 환경변수 (앱이 설정)
| 변수 | 값 | 용도 |
|---|---|---|
| `STREAM` | `1` | 상주 스트림 모드 진입 |
| `DIAR` | `1`/`0` | 화자분리 on/off |
| `OSD` | `1`/`0` | 중첩 발화 감지 on/off |
| `WHISPER_LANG_ID` | 숫자 토큰 | 언어 고정(빈값=자동) |
| `VOICEPRINTS` | 디렉터리 | 등록 음성 자동인식(선택) |
| `DIAR_MAXK` | `8` | 라이브 최대 화자 수 |

### 인자
```
transcribe <model.safetensors> <audio|/dev/null> <WHISPER_BPE.bin>
```
STREAM 모드에서 2번째 인자(wav)는 무시되므로 `/dev/null` 전달.

---

## 3. 오디오 캡처 (AVAudioEngine)

기존 러너의 캡처 사양을 그대로 재현:
- **세그먼트 길이** `SEG=10`초, **좌측 오버랩** `OVERLAP=3`초 (경계 단어 복원).
- 출력 포맷: **16 kHz, mono, 16-bit PCM WAV** (엔진 입력 사양).

흐름:
1. `AVAudioEngine.inputNode`에 tap 설치 → 하드웨어 샘플레이트(보통 44.1/48k) 수신.
2. `AVAudioConverter`로 16 kHz mono Float32 → Int16 변환.
3. 링버퍼에 누적, 10초마다 직전 3초를 prepend한 세그먼트 WAV를 temp dir에 기록.
4. 파일이 닫히면 `EngineProcess.feed(offset:path:)` 호출.
5. 세션 종료 시 `feed("FLUSH")` → `<<FLUSH_END>>` 수신 후 export.

권한: `Info.plist`의 `NSMicrophoneUsageDescription` + entitlement
`com.apple.security.device.audio-input`. 첫 tap 설치 시 OS가 권한 다이얼로그를
띄운다. `--replay <file>` 경로(파일 트랜스크립션)는 캡처를 우회하고 디코드된
PCM을 같은 세그먼터에 흘려 동일 코드패스로 처리.

---

## 4. 모델 다운로더 (첫 실행)

DMG에는 **소형 자산만** 번들(앱 ~30MB). `model.q8.safetensors`(Q8 ~830MB, F16 대비
1.86× 작음)는 첫 구동 시 다운로드:

1. 앱 시작 → `~/Library/Application Support/Sovereign/model.safetensors` 존재+해시
   확인.
2. 없거나 손상 → 다운로드 시트 표시(진행률/취소), `URLSession` 다운로드 태스크.
3. 완료 후 **SHA256 검증** (`AssetManifest`의 기대 해시와 대조) → 불일치 시 재시도.
4. 검증 통과 후 캡처 UI 해제.

호스팅: R2/S3/CDN 중 택1. URL·해시는 `AssetManifest.swift`에 박제(앱 업데이트로
모델 버전 핀 갱신). 향후 Q4 모델 옵션 추가 시 매니페스트에 변형 추가.

번들 소형 자산(이미 검증된 sovereign 포팅): `pyannote_osd.bin`(5.7M),
`silero_vad.bin`(1.2M), `resnet34_diar.bin`(25M), `WHISPER_BPE.bin`,
`mel_filters.bin`, `conv1_*/conv2_*`, `pos_emb.bin`, `suppress_tokens.bin`,
토크나이저 일습. **dev 전용 제외**: `jfk*.wav`, `enc_input.bin`, `*.py`, README.

---

## 5. 번들 구조

```
Sovereign.app/
  Contents/
    Info.plist                 # CFBundle*, LSMinimumSystemVersion, NSMicrophone…
    MacOS/
      Sovereign                # SwiftUI 실행파일 (arm64, hardened runtime)
      transcribe               # 엔진 바이너리 (metal/out/transcribe)
      whisper.metallib         # @embedFile로 이미 내장됐으나, 외부 사본도 동봉(보험)
    Resources/
      assets-small/            # 위 4절의 번들 자산
      Assets.xcassets          # 앱 아이콘 등
    _CodeSignature/
```

`transcribe`는 별도 실행파일이므로 **개별 서명 + hardened runtime** 필요(아래 7절).

---

## 6. UI/UX (독립 윈도우 앱)

화면:
- **메인 윈도우**: 실시간 자막(화자색 + 타임스탬프), 하단 녹음 상태/레벨미터,
  Start/Stop, 언어 선택, 세션 제목.
- **세션 사이드바**: 과거 세션 목록 + 재생/내보내기.
- **설정**: 입력 장치, SEG/OVERLAP, 화자분리·OSD 토글, 화자 이름 매핑
  (`0=Alice`), 보이스프린트 디렉터리, 모델 관리(재다운로드/삭제).
- **내보내기**: `.md`(끼어들기 마커 포함), `.srt`. 기존 러너 렌더링 규칙 이식.

상태 머신: `idle → downloadingModel? → engineStarting → ready → recording ⇄
paused → flushing → done`.

---

## 7. 서명 · 노터라이즈 · DMG (배포 파이프라인)

전제: **Apple Developer Program**($99/년) + **Developer ID Application** 인증서.

`app/scripts/` 단계별:

### 7.1 `build_engine.sh`
```
cd metal && ./build.sh transcribe.zig transcribe   # → metal/out/transcribe + whisper.metallib
```

### 7.2 `make_app.sh`
Xcode 프로젝트(또는 `xcodebuild`)로 `Sovereign.app` 산출 → 엔진 바이너리·metallib·
소형 자산을 번들에 복사.

### 7.3 `sign_notarize.sh`
```bash
ENT="Sovereign/Sovereign.entitlements"      # 마이크 + hardened runtime
ID="Developer ID Application: <TEAM> (<TEAMID>)"

# 1) 동봉 실행파일부터 안쪽→바깥쪽 순서로 서명
codesign --force --options runtime --timestamp \
  --entitlements "$ENT" --sign "$ID" \
  "Sovereign.app/Contents/MacOS/transcribe"
codesign --force --options runtime --timestamp --sign "$ID" \
  "Sovereign.app/Contents/MacOS/whisper.metallib"   # 리소스면 생략 가능
# 2) 앱 본체 서명 (--deep 지양; 내부는 이미 개별 서명)
codesign --force --options runtime --timestamp \
  --entitlements "$ENT" --sign "$ID" "Sovereign.app"
codesign --verify --deep --strict --verbose=2 "Sovereign.app"

# 3) 노터라이즈 (zip 제출)
ditto -c -k --keepParent "Sovereign.app" "Sovereign.zip"
xcrun notarytool submit "Sovereign.zip" \
  --apple-id "$APPLE_ID" --team-id "$TEAMID" \
  --password "$APP_SPECIFIC_PW" --wait

# 4) 티켓 스테이플
xcrun stapler staple "Sovereign.app"
```

### 7.4 `make_dmg.sh`
```bash
create-dmg --volname "Sovereign Whisper" \
  --app-drop-link 480 200 --icon "Sovereign.app" 160 200 \
  "Sovereign-1.0.dmg" "Sovereign.app"   # 또는 hdiutil create
xcrun stapler staple "Sovereign-1.0.dmg"   # DMG에도 티켓
```

### entitlements (`Sovereign.entitlements`)
```xml
<key>com.apple.security.device.audio-input</key><true/>
<!-- 자식 프로세스(transcribe)는 별도 실행파일 → 같은 hardened runtime 서명.
     JIT/메모리 관련 추가 entitlement는 필요 시 측정 후 추가. -->
```

---

## 8. 단계별 로드맵 (가치 기울기 순)

| 단계 | 산출물 | 상태 |
|---|---|---|
| 0 | **본 설계 문서 + 스캐폴드** | ← 지금 |
| 1 | AudioCapture(AVAudioEngine 16k mono 세그먼터) 실동작 | |
| 2 | EngineProcess/Protocol stdin·stdout 브리지 + live 렌더 | |
| 3 | ModelDownloader(첫 실행 + SHA256) | |
| 4 | TranscriptStore relabel/overlap + Exporters(md/srt) | |
| 5 | Settings/세션 사이드바 UI 마감 | |
| 6 | Developer ID 서명 + 노터라이즈 + DMG 파이프라인 | |
| 7 | (선택) Sparkle 자동 업데이트 | |

가장 까다로운 두 곳: **1단계 AVAudioEngine 리샘플/세그먼트 정확도**(엔진이
기대하는 16k mono + 3s 오버랩을 비트 정확히 재현)와 **6단계 노터라이즈 첫
셋업**(인증서·entitlement·동봉 바이너리 서명 순서). 나머지는 검증된 엔진을 감싸는
배관이라 리스크가 낮다.

---

## 9. 미해결/결정 보류

- **호스팅**: 모델 CDN 선택(R2 추천 — egress 무료). URL/해시 매니페스트 확정 필요.
- **앱 아이콘/브랜딩**: 별도.
- **샌드박스**: 현재 설계는 hardened runtime(노터라이즈용)만. Mac App Store
  배포로 가면 App Sandbox + 임시 파일 접근 entitlement 재설계 필요 → 현 단계는
  Developer ID 직배포(DMG)만 대상.
- **Q4 모델 옵션**: 다운로드 반감(750MB) 가치 있으나 WER/DER 회귀 검증 선행.
