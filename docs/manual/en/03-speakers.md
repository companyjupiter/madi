# Speakers & Diarization

Madi automatically figures out who spoke during a meeting, and once you name a voice, it recognizes that same voice in future meetings. All of this runs on this Mac.

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

## Automatic speaker separation

While recording and transcribing, Madi splits speech by speaker automatically.

- Each speaker gets a colored dot and a **화자 N** (Speaker N) label.
- If you know how many people are present, fix the count in **설정 → 녹음 → 화자 수** (Settings → Recording → Speaker count) to improve separation.

## Naming speakers

1. In the transcript, click a speaker name (e.g. **화자 1** / Speaker 1) or speaker chip.
2. Type the real name in the **화자 이름** (Speaker name) field — for example, 김부장.
3. The name applies to **all of that speaker's lines and to exports**.

## Voiceprints (recognized by voice)

When you name a speaker, Madi enrolls that person's **voiceprint**. From then on, it **auto-recognizes the same voice in future meetings** and labels it with the same name. All of this happens on this Mac.

- A speaker recognized by voice shows a **✓ 음성 인식됨** (recognized by voice) badge, meaning the voice matched an enrolled one.
- Voiceprint recognition works **for live recording only** — it does not apply to file transcription.

### Managing enrolled voiceprints

1. In the workspace explorer, go to the **사람** (People) area (or reach it from Settings).
2. Review the list of enrolled voices by name.
3. Use the **삭제** (Delete) button to remove a voice you no longer need.

**Note**
- If nothing is enrolled yet, you'll see "등록된 음성이 없습니다" (No enrolled voices). Naming a speaker during a meeting enrolls that voice, so it's recognized automatically next time.

## Talk time & People dashboard

See at a glance who spoke how much.

- In the transcript, **발언 시간** (Talk time) shows how much each speaker spoke.
- The **사람** (People) tab in the workspace explorer aggregates one person's talk time **across multiple meetings**. Each enrolled voice gets its own card.

**Note**
- If no speakers are enrolled, you'll see "등록된 화자가 없습니다" (No enrolled speakers). Naming a speaker enrolls the voice, and per-meeting talk time accumulates here.

## Overlap markers

When two people talk at the same time, an **overlap marker** appears in the **상세** (Detailed) view to flag the second speaker in that stretch.

**Note**
- Overlap markers appear only in the **상세** (Detailed) view. Switch from **내용 → 상세** (Content → Detailed) at the top of the window.
