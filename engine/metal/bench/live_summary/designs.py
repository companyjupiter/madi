"""Candidate redesigns of the live rolling summary, measured on the same replay as baseline."""
import re
from harness import sanitize, bullets, baseline_prompt

LANG_PIN = "반드시 발언과 같은 언어로만 답하세요(발언이 영어면 영어로). "


def _trigrams(s):
    s = re.sub(r'\s+', '', s.lower())
    return {s[i:i + 3] for i in range(max(0, len(s) - 2))}

def near_dup(a, b, thr=0.55):
    A, B = _trigrams(a), _trigrams(b)
    return bool(A and B) and len(A & B) / len(A | B) >= thr

def is_none(line):
    return re.sub(r'[\s.。!-]', '', line) in ('없음', 'none', 'None', '')


class BiggerBudget:
    """Control: today's rolling carry, only with ~3x the input budget and more bullets.
    Separates 'the budget is too small' from 're-compressing the carry drifts'."""
    name = 'bigger'
    def __init__(self): self.carry = None
    def update(self, eng, new_rows, upto):
        w = ' / '.join(f'{s}: {x}' for _, s, x in new_rows)[-2000:]
        c = (self.carry or '').replace('\n', ' ')[:1200]
        if not c:
            p = ("다음은 진행 중인 회의의 최근 발언입니다. 지금까지의 핵심을 4-8개 불릿으로 요약하세요. " + LANG_PIN +
                 f"각 줄을 - 로 시작, 다른 말 없이 불릿만. 발언: {w}")
        else:
            p = ("다음은 진행 중인 회의의 기존 요약과 새 발언입니다. 새 발언을 반영해 핵심 요약을 4-8개 불릿으로 갱신하세요. "
                 "여전히 중요한 항목은 유지하고 새 내용을 반영하세요. " + LANG_PIN +
                 f"각 줄을 - 로 시작, 다른 말 없이 불릿만. 기존 요약: {c} 새 발언: {w}")
        r = eng.turn(p); r['kind'] = 'rewrite'
        clean = sanitize(r['text'])
        if clean: self.carry = clean
        return [r]
    def pane(self): return bullets(self.carry or '')


class TwoLevel:
    """Append-only grounded notes per tick + per-5-minute group consolidation.
    Notes come from raw lines exactly once; groups only ever read their own notes,
    so nothing is re-compressed across the meeting."""
    name = 'twolevel'
    GROUP_SEC = 300
    RECENT_CTX = 4

    def __init__(self):
        self.notes = []          # {t0,t1,text,span:(i0,i1),group}
        self.groups = {}         # group index -> consolidated bullets
        self.line_index = 0
        self.last_t = 0

    def _note_prompt(self, window, recent):
        ctx = ' / '.join(recent) if recent else '없음'
        return ("다음은 진행 중인 회의의 새 발언입니다. 이 발언에서 새로 나온 구체적인 내용"
                "(결정, 할 일과 담당, 수치·금액, 고유명사가 있는 사실, 쟁점)만 0~2개 골라 한 줄씩 쓰세요. "
                "이미 기록한 항목과 같은 내용이면 쓰지 마세요. 인사·잡담·말 끊김뿐이면 '없음'이라고만 답하세요. "
                + LANG_PIN + "각 줄을 - 로 시작, 다른 말 없이. "
                f"이미 기록한 항목: {ctx} 새 발언: {window}")

    def _group_prompt(self, g, notes):
        a, b = g * self.GROUP_SEC, (g + 1) * self.GROUP_SEC
        items = ' / '.join(n['text'] for n in notes)
        return (f"다음은 회의 {a//60:02d}:{a%60:02d}–{b//60:02d}:{b%60:02d} 구간에서 기록한 항목입니다. "
                "같은 내용은 합쳐 1~3개 불릿으로 정리하세요. 항목에 없는 내용은 추가하지 마세요. "
                "이름·수치·결정은 그대로 남기세요. 반드시 항목과 같은 언어로만 답하세요. "
                f"각 줄을 - 로 시작, 다른 말 없이. 항목: {items}")

    def update(self, eng, new_rows, upto):
        reqs = []
        t_now = new_rows[-1][0]
        # close finished 5-minute groups first (their notes are final)
        cur_g = t_now // self.GROUP_SEC
        for g in sorted({n['group'] for n in self.notes}):
            if g < cur_g and g not in self.groups:
                gn = [n for n in self.notes if n['group'] == g]
                if len(gn) <= 2:
                    self.groups[g] = [n['text'] for n in gn]
                else:
                    r = eng.turn(self._group_prompt(g, gn)); r['kind'] = 'group'; reqs.append(r)
                    out = [b for b in bullets(sanitize(r['text'])) if not is_none(b)]
                    self.groups[g] = out or [n['text'] for n in gn]
        window = ' / '.join(f'{s}: {x}' for _, s, x in new_rows)[-700:]
        recent = [n['text'] for n in self.notes[-self.RECENT_CTX:]]
        r = eng.turn(self._note_prompt(window, recent)); r['kind'] = 'note'; reqs.append(r)
        i0 = len(upto) - len(new_rows)
        for b in bullets(sanitize(r['text']))[:2]:
            if is_none(b) or len(b) < 6: continue
            if any(near_dup(b, n['text']) for n in self.notes[-10:]): continue
            self.notes.append({'t0': new_rows[0][0], 't1': t_now, 'text': b,
                               'span': (i0, len(upto) - 1), 'group': new_rows[0][0] // self.GROUP_SEC})
        return reqs

    def pane(self):
        out = []
        groups = sorted({n['group'] for n in self.notes})
        for g in groups:
            items = self.groups.get(g) or [n['text'] for n in self.notes if n['group'] == g]
            out.append(f'⟪{g*5:02d}–{g*5+5:02d}분⟫')
            out += items
        return out

    def pane_raw(self):
        return [f"[{n['t0']//60:02d}:{n['t0']%60:02d}] {n['text']}" for n in self.notes]


DESIGNS = {'bigger': BiggerBudget, 'twolevel': TwoLevel}


# ───────────────────────── v2 ─────────────────────────
LANG_NAME = {'ko': '한국어', 'en': '영어', 'ja': '일본어', 'zh': '중국어'}

def script_counts(s):
    h = sum('가' <= c <= '힣' or 'ㄱ' <= c <= 'ㆎ' for c in s)
    k = sum('぀' <= c <= 'ヿ' for c in s)
    z = sum('一' <= c <= '鿿' for c in s)
    l = sum(c.isascii() and c.isalpha() for c in s)
    return h, k, z, l

def dominant_lang(text):
    h, k, z, l = script_counts(text)
    if h >= 0.3 * (h + k + z + l) and h > 0: return 'ko'
    if k > 0 and k + z >= 0.3 * (h + k + z + l): return 'ja'
    if z >= 0.3 * (h + k + z + l) and z > 0: return 'zh'
    return 'en'

def script_ok(line, lang):
    h, k, z, l = script_counts(line); tot = h + k + z + l
    if tot == 0: return False
    if lang == 'ko': return h >= 0.4 * tot and z == 0 and k == 0       # Latin names/acronyms allowed
    if lang == 'en': return h == 0 and k == 0 and z == 0
    if lang == 'ja': return k > 0 and h == 0
    if lang == 'zh': return z > 0 and h == 0 and k == 0
    return True

ANON = re.compile(r'^(Speaker|화자)\s*\d+\s*[:：]\s*')

def dup_of(a, b):
    """near-duplicate OR one mostly contained in the other (echo / split of an earlier note)"""
    A, B = _trigrams(a), _trigrams(b)
    if not A or not B: return False
    inter = len(A & B)
    return inter / len(A | B) >= 0.5 or inter / min(len(A), len(B)) >= 0.8


class TwoLevelV2(TwoLevel):
    """v2: deterministic language pin + output script gate, no echo-prone context, skip
    unclear speech, one fact per line, anonymous speaker prefix stripped, dedupe against
    every note (containment-aware), group consolidation hard-capped."""
    name = 'twolevel2'
    GROUP_CAP = 3
    USE_CONTEXT = False

    def __init__(self):
        super().__init__(); self.lang = None; self.dropped = {'script': 0, 'dup': 0, 'none': 0}

    def _note_prompt(self, window, recent):
        ln = LANG_NAME[self.lang]
        ctx = (f"이미 기록한 항목: {' / '.join(recent)} " if (self.USE_CONTEXT and recent) else "")
        return ("다음은 진행 중인 회의의 새 발언입니다. 이 발언에서 새로 나온 구체적인 내용"
                "(결정, 할 일과 담당, 수치·금액, 고유명사가 있는 사실, 쟁점)만 0~2개 골라 쓰세요. "
                "한 줄에 한 가지만, 짧은 한 문장으로. 뜻이 불분명하거나 말이 끊긴 발언은 건너뛰고, "
                "인사·잡담뿐이면 '없음'이라고만 답하세요. "
                f"반드시 {ln}로만 답하세요. 각 줄을 - 로 시작, 다른 말 없이. {ctx}새 발언: {window}")

    def _group_prompt(self, g, notes):
        a, b = g * self.GROUP_SEC, (g + 1) * self.GROUP_SEC
        items = ' / '.join(n['text'] for n in notes)
        return (f"다음은 회의 {a//60:02d}:{a%60:02d}–{b//60:02d}:{b%60:02d} 구간에서 기록한 항목입니다. "
                f"가장 중요한 것부터 최대 {self.GROUP_CAP}개 불릿으로 정리하세요. 같은 내용은 하나로 합치되, "
                "각 불릿은 한 가지 내용만 한 문장으로. 항목에 없는 내용은 추가하지 마세요. "
                "이름·수치·결정은 그대로 남기세요. "
                f"반드시 {LANG_NAME[self.lang]}로만 답하세요. 각 줄을 - 로 시작, 다른 말 없이. 항목: {items}")

    def _clean(self, b):
        return ANON.sub('', b).strip()

    def update(self, eng, new_rows, upto):
        if self.lang is None or len(upto) % 50 < len(new_rows):     # settle/refresh from the whole transcript
            self.lang = dominant_lang(' '.join(x for _, _, x in upto))
        reqs = []
        t_now = new_rows[-1][0]; cur_g = t_now // self.GROUP_SEC
        for g in sorted({n['group'] for n in self.notes}):
            if g < cur_g and g not in self.groups:
                gn = [n for n in self.notes if n['group'] == g]
                if len(gn) <= self.GROUP_CAP:
                    self.groups[g] = [n['text'] for n in gn]
                else:
                    r = eng.turn(self._group_prompt(g, gn)); r['kind'] = 'group'; reqs.append(r)
                    out = [self._clean(b) for b in bullets(sanitize(r['text']))]
                    out = [b for b in out if not is_none(b) and script_ok(b, self.lang)][:self.GROUP_CAP]
                    self.groups[g] = out or [n['text'] for n in gn][:self.GROUP_CAP]
        window = ' / '.join(f'{s}: {x}' for _, s, x in new_rows)[-700:]
        recent = [n['text'] for n in self.notes[-self.RECENT_CTX:]]
        r = eng.turn(self._note_prompt(window, recent)); r['kind'] = 'note'; reqs.append(r)
        i0 = len(upto) - len(new_rows)
        for b in bullets(sanitize(r['text']))[:2]:
            b = self._clean(b)
            if is_none(b) or len(b) < 6: self.dropped['none'] += 1; continue
            if not script_ok(b, self.lang): self.dropped['script'] += 1; continue
            if any(dup_of(b, n['text']) for n in self.notes): self.dropped['dup'] += 1; continue
            self.notes.append({'t0': new_rows[0][0], 't1': t_now, 'text': b,
                               'span': (i0, len(upto) - 1), 'group': new_rows[0][0] // self.GROUP_SEC})
        return reqs

    def pane_raw(self):
        return super().pane_raw() + [f'dropped: {self.dropped}', f'lang: {self.lang}']


class TwoLevelV2Ctx(TwoLevelV2):
    """v2 with the 'already noted' context restored — isolates whether context causes echo."""
    name = 'twolevel2ctx'
    USE_CONTEXT = True


DESIGNS.update({'twolevel2': TwoLevelV2, 'twolevel2ctx': TwoLevelV2Ctx})


class TwoLevelV3(TwoLevelV2):
    """v3: no decision over-claiming (only when explicitly stated), one short sentence per
    line, no comma lists, skip words that look misheard."""
    name = 'twolevel3'

    def _note_prompt(self, window, recent):
        ln = LANG_NAME[self.lang]
        return ("다음은 진행 중인 회의의 새 발언입니다. 이 발언에서 새로 나온 구체적인 내용만 0~2개 골라 쓰세요. "
                "이름·수치·금액·제품명처럼 구체적인 것을 살리고, 한 줄에 한 가지만 짧은 한 문장으로 쓰세요. "
                "'결정'이나 '합의'는 발언에서 분명히 정했다고 말한 경우에만 쓰고, 아니면 '논의'나 '제안'으로 쓰세요. "
                "잘못 들린 듯 뜻이 통하지 않는 말, 말이 끊긴 발언은 건너뛰고, 인사·잡담뿐이면 '없음'이라고만 답하세요. "
                f"반드시 {ln}로만 답하세요. 각 줄을 - 로 시작, 다른 말 없이. 새 발언: {window}")

    def _group_prompt(self, g, notes):
        a, b = g * self.GROUP_SEC, (g + 1) * self.GROUP_SEC
        items = ' / '.join(n['text'] for n in notes)
        return (f"다음은 회의 {a//60:02d}:{a%60:02d}–{b//60:02d}:{b%60:02d} 구간에서 기록한 항목입니다. "
                f"가장 중요한 것부터 최대 {self.GROUP_CAP}개 불릿으로 정리하세요. 같은 내용만 하나로 합치고, "
                "각 불릿은 한 가지 내용의 짧은 한 문장으로 쓰세요. 쉼표로 여러 내용을 나열하지 마세요. "
                "항목에 없는 내용은 추가하지 말고, '결정'은 항목에 결정이라고 적힌 경우에만 쓰세요. "
                "이름·수치는 그대로 남기세요. "
                f"반드시 {LANG_NAME[self.lang]}로만 답하세요. 각 줄을 - 로 시작, 다른 말 없이. 항목: {items}")


DESIGNS.update({'twolevel3': TwoLevelV3})


class NotesV4(TwoLevelV3):
    """v4: notes only (no LLM group consolidation — that step is what crammed comma lists);
    at most ONE note per request, the most important; a slightly wider window and a higher
    new-line gate so a request carries a meaningful chunk. 5-minute groups are display-only."""
    name = 'notes4'
    MIN_NEW = 10
    WINDOW_CAP = 1000
    PER_TICK = 1

    def _note_prompt(self, window, recent):
        ln = LANG_NAME[self.lang]
        return ("다음은 진행 중인 회의의 새 발언입니다. 이 발언에서 가장 중요한 구체적인 내용 하나만 짧은 한 문장으로 쓰세요. "
                "이름·수치·금액·제품명처럼 구체적인 것을 살리세요. "
                "'결정'이나 '합의'는 발언에서 분명히 정했다고 말한 경우에만 쓰고, 아니면 '논의'나 '제안'으로 쓰세요. "
                "잘못 들린 듯 뜻이 통하지 않는 말은 쓰지 말고, 인사·잡담뿐이면 '없음'이라고만 답하세요. "
                f"반드시 {ln}로만 답하세요. - 로 시작, 다른 말 없이. 새 발언: {window}")

    def update(self, eng, new_rows, upto):
        if self.lang is None or len(upto) % 50 < len(new_rows):
            self.lang = dominant_lang(' '.join(x for _, _, x in upto))
        window = ' / '.join(f'{s}: {x}' for _, s, x in new_rows)[-self.WINDOW_CAP:]
        r = eng.turn(self._note_prompt(window, [])); r['kind'] = 'note'
        i0 = len(upto) - len(new_rows)
        for b in bullets(sanitize(r['text']))[:self.PER_TICK]:
            b = self._clean(b)
            if is_none(b) or len(b) < 6: self.dropped['none'] += 1; continue
            if not script_ok(b, self.lang): self.dropped['script'] += 1; continue
            if any(dup_of(b, n['text']) for n in self.notes): self.dropped['dup'] += 1; continue
            self.notes.append({'t0': new_rows[0][0], 't1': new_rows[-1][0], 'text': b,
                               'span': (i0, len(upto) - 1), 'group': new_rows[0][0] // self.GROUP_SEC})
        return [r]

    def pane(self):
        out = []
        for g in sorted({n['group'] for n in self.notes}):
            out.append(f'⟪{g*5:02d}–{g*5+5:02d}분⟫')
            out += [n['text'] for n in self.notes if n['group'] == g]
        return out


DESIGNS.update({'notes4': NotesV4})


ANON_SPK = re.compile(r'^(Speaker\s*\d+|화자\s*\d*)$')
ECHO = re.compile(r'^(이\s*)?발언에서\s*(가장\s*)?(중요한\s*)?(구체적인\s*)?내용은\s*')


class NotesV5(NotesV4):
    """v5 = v4 + anonymous speakers unlabeled in the window (named ones kept), length asked
    in the prompt, prompt-echo prefix stripped, runaway (> 140 chars) dropped."""
    name = 'notes5'
    MAX_CHARS = 140

    @staticmethod
    def _line(s, x):
        return x if ANON_SPK.match(s.strip()) else f'{s}: {x}'

    def _note_prompt(self, window, recent):
        ln = LANG_NAME[self.lang]
        return ("다음은 진행 중인 회의의 새 발언입니다. 이 발언에서 가장 중요한 구체적인 내용 하나만 50자 안팎의 한 문장으로 쓰세요. "
                "이름·수치·금액·제품명처럼 구체적인 것을 살리세요. "
                "'결정'이나 '합의'는 발언에서 분명히 정했다고 말한 경우에만 쓰고, 아니면 '논의'나 '제안'으로 쓰세요. "
                "잘못 들린 듯 뜻이 통하지 않는 말은 쓰지 말고, 인사·잡담뿐이면 '없음'이라고만 답하세요. "
                f"반드시 {ln}로만 답하세요. - 로 시작, 다른 말 없이. 새 발언: {window}")

    def _clean(self, b):
        return ECHO.sub('', ANON.sub('', b)).strip()

    def update(self, eng, new_rows, upto):
        if self.lang is None or len(upto) % 50 < len(new_rows):
            self.lang = dominant_lang(' '.join(x for _, _, x in upto))
        window = ' / '.join(self._line(s, x) for _, s, x in new_rows)[-self.WINDOW_CAP:]
        r = eng.turn(self._note_prompt(window, [])); r['kind'] = 'note'
        i0 = len(upto) - len(new_rows)
        for b in bullets(sanitize(r['text']))[:self.PER_TICK]:
            b = self._clean(b)
            if is_none(b) or len(b) < 6: self.dropped['none'] += 1; continue
            if len(b) > self.MAX_CHARS: self.dropped.setdefault('long', 0); self.dropped['long'] += 1; continue
            if not script_ok(b, self.lang): self.dropped['script'] += 1; continue
            if any(dup_of(b, n['text']) for n in self.notes): self.dropped['dup'] += 1; continue
            self.notes.append({'t0': new_rows[0][0], 't1': new_rows[-1][0], 'text': b,
                               'span': (i0, len(upto) - 1), 'group': new_rows[0][0] // self.GROUP_SEC})
        return [r]


DESIGNS.update({'notes5': NotesV5})


ANON_ANY = re.compile(r'(?:Speaker|화자)\s*\d+\s*(?:님)?(?:은|는|이|가|께서|의)?\s*')


class NotesV6(NotesV5):
    """v6 = v5, but EVERY speaker is labeled in the window (as the app displays them) so the
    model can tell who said what; anonymous labels are removed from the note afterwards.
    v5 left anonymous lines unlabeled and the model attributed them to the named speaker."""
    name = 'notes6'

    @staticmethod
    def _line(s, x):
        return f'{s}: {x}'

    def _clean(self, b):
        b = ECHO.sub('', ANON.sub('', b)).strip()
        b = ANON_ANY.sub('', b).strip()
        return b[:1].upper() + b[1:] if b and b[0].isascii() else b


DESIGNS.update({'notes6': NotesV6})
