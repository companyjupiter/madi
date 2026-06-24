#!/usr/bin/env python3
# Korean TTS diarization fixtures (macOS `say` ko_KR voices) + ground-truth RTTM.
# Mirrors gen_demo4.py but Korean, across the 1 / 2 / multi(4) speaker buckets so
# the KO language axis has objective DER (no public KO diar reference exists).
#   → bench/ko1.wav ko1.ref.rttm  (single speaker monologue, K=1 gate test)
#   → bench/ko2.wav ko2.ref.rttm  (2-person dialogue)
#   → bench/ko4.wav ko4.ref.rttm  (4-person meeting)
import subprocess, os, wave

os.makedirs("/tmp/sayko", exist_ok=True)
HERE = os.path.dirname(os.path.abspath(__file__))
# ffmpeg in this env is broken (missing x265 dylib); use macOS-native afconvert
# for aiff→16k mono s16le and concatenate raw PCM with the wave module.

def to_wav(aiff, wav):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)

def build(name, turns):
    frames, rttm, t = [], [], 0.0
    for i, (v, txt) in enumerate(turns):
        a, w = f"/tmp/sayko/{name}_{i}.aiff", f"/tmp/sayko/{name}_{i}.wav"
        subprocess.run(["say", "-v", v, "-o", a, txt], check=True)
        to_wav(a, w)
        wr = wave.open(w); n = wr.getnframes()
        dur = n / 16000
        rttm.append(f"SPEAKER {name} 1 {t:.3f} {dur:.3f} <NA> <NA> {v} <NA> <NA>")
        t += dur
        frames.append(wr.readframes(n)); wr.close()
    out = wave.open(f"{HERE}/{name}.wav", "w")
    out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
    out.writeframes(b"".join(frames)); out.close()
    open(f"{HERE}/{name}.ref.rttm", "w").write("\n".join(rttm) + "\n")
    print(f"{name}.wav {t:.1f}s, {len({v for v,_ in turns})} speakers / {len(turns)} turns")

# 1 speaker — monologue with natural sentence pauses (K=1 gate + VAD on KO)
build("ko1", [
    ("Yuna", "안녕하세요. 오늘은 클라우드 네이티브 아키텍처에 대해 이야기해 보겠습니다."),
    ("Yuna", "컨테이너 오케스트레이션은 이제 운영의 표준이 되었습니다."),
    ("Yuna", "하지만 비용 최적화와 보안은 여전히 어려운 과제로 남아 있습니다."),
    ("Yuna", "오늘 발표에서는 이 두 가지 문제를 차근차근 살펴보려고 합니다."),
    ("Yuna", "그럼 본격적으로 시작해 보겠습니다. 잘 따라와 주시기 바랍니다."),
])

# 2 speakers — Q&A dialogue
build("ko2", [
    ("Yuna", "안녕하세요. 이번 분기 인프라 마이그레이션 진행 상황을 공유해 주시겠어요?"),
    ("Eddy", "네, 현재 전체 워크로드의 절반 정도를 쿠버네티스로 옮겼습니다."),
    ("Yuna", "비용 측면에서는 효과가 좀 있었나요?"),
    ("Eddy", "예상보다 큰 절감 효과가 있었고, 자동 스케일링 덕분에 야간 비용이 줄었습니다."),
    ("Yuna", "좋네요. 그러면 남은 절반은 언제쯤 완료될 예정인가요?"),
    ("Eddy", "다음 분기 말까지는 모든 서비스를 이전하는 것을 목표로 하고 있습니다."),
    ("Yuna", "보안 점검도 마이그레이션과 함께 진행되고 있는 거죠?"),
    ("Eddy", "물론입니다. 이미지 스캔과 정책 검증을 파이프라인에 통합해 두었습니다."),
])

# 4 speakers — meeting (multi bucket)
build("ko4", [
    ("Yuna", "자, 다들 모이셨으니 새 서비스 설계 리뷰를 시작하겠습니다."),
    ("Eddy", "네, 제안서를 봤는데 지연 시간 부분이 조금 걱정됩니다."),
    ("Sandy", "맞아요, 리전 간 호출이 늘어나면 오버헤드가 커질 수 있습니다."),
    ("Reed", "동의합니다. 대신 캐시를 적극적으로 활용하면 왕복 횟수를 줄일 수 있어요."),
    ("Yuna", "좋은 지적이에요. 결정하기 전에 예상 트래픽부터 정량화해 봅시다."),
    ("Eddy", "오후에 부하 테스트를 돌려서 내일 수치를 공유하겠습니다."),
    ("Sandy", "리전 장애 상황에 대한 시나리오도 꼭 포함해 주세요."),
    ("Reed", "캐시 무효화 전략도 명확하게 문서로 정리해야 할 것 같습니다."),
    ("Yuna", "좋습니다. 목요일에 데이터와 최종안을 가지고 다시 모이죠."),
    ("Eddy", "저는 좋습니다. 회의 끝나고 바로 일정 초대를 보내겠습니다."),
    ("Sandy", "저도 괜찮습니다. 다들 오늘 깊이 있는 논의 감사합니다."),
    ("Reed", "네, 그럼 목요일에 뵙겠습니다. 좋은 하루 보내세요."),
])
