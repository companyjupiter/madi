// GlossarySettingsView.swift — the Settings (⌘,) tab that exposes the PERSONAL
// VOCABULARY feature to the user. The learning + auto-correction cores
// (GlossaryStore.swift, PersonalVocabulary.swift) already run silently inside
// SessionController: editLine() teaches new corrections and the ingest/finalize
// pipeline applies them. This view is the only user-facing surface:
//
//   1. master gate (glossary.enabled) — auto-substitution is OFF by default; the
//      user opts in. Learning happens regardless, so flipping it on works at once.
//   2. minHits slider — how many times a correction must be confirmed before it's
//      trusted enough to rewrite future transcripts (guards a single fat-finger edit).
//   3. management list — every learned rule (wrong → right, hit count), with a per-
//      row "잊기" (forget) button and a "전체 지우기" (clear all) so a bad rule that
//      lands can be removed without touching UserDefaults by hand.
//
// SessionController.glossary has no didSet persister, so every mutation made here
// is followed by session.glossary.save() to write it back to UserDefaults.

import SwiftUI

struct GlossarySettingsView: View {
    @Bindable var session: SessionController

    var body: some View {
        Form {
            Section("개인 단어장") {
                Toggle("학습한 교정 자동 적용", isOn: Binding(
                    get: { session.glossary.enabled },
                    set: { session.glossary.enabled = $0; session.glossary.save() }
                ))
                Text("전사 중 자주 틀리는 도메인 용어·이름을 직접 고친 내용을 기억해, 이후 회의의 비슷한 오인식을 자동으로 바로잡습니다. 학습은 항상 동작하고, 이 스위치는 ‘적용’만 켭니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("적용 기준") {
                HStack {
                    Text("최소 확인 횟수")
                    Slider(value: Binding(
                        get: { Double(session.glossary.minHits) },
                        set: { session.glossary.minHits = Int($0.rounded()); session.glossary.save() }
                    ), in: 1...5, step: 1)
                    Text("\(session.glossary.minHits)회")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!session.glossary.enabled)
                Text("같은 교정을 이 횟수 이상 확인해야 자동 적용합니다. 값이 클수록 보수적입니다(우발적 편집이 이후 전사를 덮어쓰지 않도록).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("학습한 교정 (\(activeCount)/\(totalCount))") {
                if entries.isEmpty {
                    Text("아직 학습한 교정이 없습니다. 전사문에서 잘못 인식된 단어를 직접 고치면 여기에 쌓입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.wrong) { e in
                        HStack(spacing: Theme.Space.chipGap) {
                            Text(e.wrong)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .strikethrough()
                            Image(systemName: "arrow.right")
                                .font(.caption2).foregroundStyle(Theme.Colors.textTertiary)
                            Text(e.right)
                                .fontWeight(.semibold)
                                .foregroundStyle(active(e) ? Theme.Colors.textPrimary
                                                            : Theme.Colors.textTertiary)
                            Spacer()
                            Text("\(e.hits)회")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(active(e) ? Theme.Colors.accent
                                                            : Theme.Colors.textTertiary)
                            Button {
                                session.glossary.forget(e.wrong)
                                session.glossary.save()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("이 교정을 잊기")
                        }
                        .help(active(e) ? "적용 중" : "확인 횟수 부족 — 아직 적용 안 됨")
                    }
                    Button("전체 지우기", role: .destructive) {
                        session.glossary.clear()
                        session.glossary.save()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // All learned rules, strongest first (then alphabetical) so the most-trusted
    // corrections surface at the top of the list.
    private var entries: [GlossaryEntry] {
        session.glossary.entries.values.sorted {
            $0.hits != $1.hits ? $0.hits > $1.hits : $0.wrong < $1.wrong
        }
    }
    private var totalCount: Int { session.glossary.entries.count }
    private var activeCount: Int { session.glossary.activeEntries.count }
    // A rule is "active" (eligible to auto-correct) once it clears the minHits bar.
    private func active(_ e: GlossaryEntry) -> Bool {
        e.hits >= max(1, session.glossary.minHits)
    }
}
