// FAQTranslationStore.swift — session-invariant, disk-persistent pre-translated
// phrase bank (T8, 2026-07-05). The InterimTranslationCache (O3) is LRU-15 and
// session-scoped; recurring CLINIC phrases ("시술 후 3일간 사우나를 피해 주세요")
// are re-translated by DNA3 every session. A pre-translated hit costs 0 ms and
// skips the engine turn entirely — the translation appears WITH the transcript.
//
// Matching is deliberately CONSERVATIVE: normalized EXACT match only (strip
// whitespace + punctuation, lowercase). Fuzzy matching was rejected — a near-
// miss that surfaces the WRONG instruction in a medical context is worse than
// a cache miss (verification T8, 2026-07-03).
//
// The store is symmetric: every language column indexes into the same entry,
// so a Japanese patient's stock question resolves to Korean just like a Korean
// staff phrase resolves to Japanese.
//
// File: Application Support/Sovereign/faq_translations.json — user-editable;
// seeded with a dermatology-clinic starter pack on first load (marked for
// review: translations are conventional clinic phrasing, not model output).

import Foundation

struct FAQTranslationStore {
    /// One phrase in every language it's known in ("Korean"/"Japanese"/…).
    typealias Entry = [String: String]

    private var entries: [Entry] = []
    /// normalized text → entry index (built over EVERY language column)
    private var index: [String: Int] = [:]

    // MARK: lookup

    /// Translations of `text` into every OTHER language of its entry, or nil.
    func lookup(_ text: String) -> [String: String]? {
        guard let key = Self.normalize(text), let i = index[key] else { return nil }
        let entry = entries[i]
        // drop the matched source column itself
        guard let srcLang = entry.first(where: { Self.normalize($0.value) == key })?.key
        else { return nil }
        let others = entry.filter { $0.key != srcLang }
        return others.isEmpty ? nil : others
    }

    /// Strong normalization: lowercase, strip ALL whitespace + punctuation.
    /// Nil for effectively-empty strings (never index those).
    static func normalize(_ s: String) -> String? {
        let stripped = s.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        let out = String(String.UnicodeScalarView(stripped))
        return out.count >= 4 ? out : nil   // too-short keys over-match ("네" 등)
    }

    // MARK: construction / persistence

    init(entries: [Entry] = []) {
        self.entries = entries
        rebuildIndex()
    }

    private mutating func rebuildIndex() {
        index.removeAll()
        for (i, e) in entries.enumerated() {
            for (_, text) in e {
                if let k = Self.normalize(text) { index[k] = i }
            }
        }
    }

    /// Load from disk; seed the starter pack when the file doesn't exist yet.
    static func load(from url: URL) -> FAQTranslationStore {
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode([Entry].self, from: data) {
            return FAQTranslationStore(entries: parsed)
        }
        let store = FAQTranslationStore(entries: starterPack)
        if let data = try? JSONEncoder().encode(starterPack) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        return store
    }

    /// Dermatology-clinic starter pack (KO staff phrases + patient stock
    /// questions). Conventional phrasing — the JSON on disk is the editable
    /// source of truth; clinics replace/extend it with their own wording.
    static let starterPack: [Entry] = [
        ["Korean": "오늘은 어떤 시술 상담을 도와드릴까요?",
         "Japanese": "本日はどのような施術のご相談でしょうか?",
         "Chinese": "今天想咨询什么项目呢?"],
        ["Korean": "시술 후 3일간 사우나와 격한 운동은 피해 주세요.",
         "Japanese": "施術後3日間はサウナと激しい運動をお控えください。",
         "Chinese": "术后三天请避免桑拿和剧烈运动。"],
        ["Korean": "시술 부위에 붉은 기가 있으면 냉찜질을 해 주세요.",
         "Japanese": "施術部位に赤みがある場合は、冷やしてください。",
         "Chinese": "如果术后部位发红，请冷敷。"],
        ["Korean": "마취 크림을 먼저 발라 드리겠습니다. 20분 정도 기다려 주세요.",
         "Japanese": "先に麻酔クリームを塗ります。20分ほどお待ちください。",
         "Chinese": "先为您涂麻醉膏，请等待约20分钟。"],
        ["Korean": "오늘 세안은 피하시고 내일부터 순한 클렌저를 사용해 주세요.",
         "Japanese": "本日は洗顔を避け、明日から低刺激の洗顔料をお使いください。",
         "Chinese": "今天请不要洗脸，明天开始使用温和的洗面奶。"],
        ["Korean": "보습제와 자외선 차단제를 꼭 발라 주세요.",
         "Japanese": "保湿剤と日焼け止めを必ず塗ってください。",
         "Chinese": "请务必涂抹保湿霜和防晒霜。"],
        ["Korean": "통증이 심하면 처방해 드린 연고를 발라 주세요.",
         "Japanese": "痛みが強い場合は、処方した軟膏を塗ってください。",
         "Chinese": "如果疼痛明显，请涂抹处方药膏。"],
        ["Korean": "다음 예약은 2주 뒤로 잡아 드릴까요?",
         "Japanese": "次のご予約は2週間後でよろしいですか?",
         "Chinese": "下次预约安排在两周后可以吗?"],
        ["Korean": "수납은 카드와 현금 모두 가능합니다.",
         "Japanese": "お支払いはカードでも現金でも可能です。",
         "Chinese": "可以刷卡或付现金。"],
        ["Korean": "건강보험은 적용되지 않는 시술입니다.",
         "Japanese": "この施術は健康保険の適用外です。",
         "Chinese": "该项目不适用医疗保险。"],
        ["Japanese": "施術のあと、どのくらいで赤みが引きますか?",
         "Korean": "시술 후 붉은 기는 얼마나 지나면 가라앉나요?",
         "Chinese": "术后多久红肿会消退?"],
        ["Japanese": "痛みはありますか?",
         "Korean": "아픈가요?",
         "Chinese": "会痛吗?"],
        ["Japanese": "今日、シャワーを浴びてもいいですか?",
         "Korean": "오늘 샤워해도 되나요?",
         "Chinese": "今天可以洗澡吗?"],
        ["Japanese": "化粧はいつからできますか?",
         "Korean": "화장은 언제부터 할 수 있나요?",
         "Chinese": "什么时候可以化妆?"],
        ["Chinese": "多久做一次比较好?",
         "Korean": "얼마 간격으로 받는 게 좋나요?",
         "Japanese": "どのくらいの間隔で受けるのがいいですか?"],
    ]
}
