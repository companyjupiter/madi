export function wrapped(index: number, delta: number, count: number) {
  return count > 0 ? ((index + delta) % count + count) % count : 0;
}
// TranscriptView.applyReview computes the successor from the pre-edit list.
// The native display snapshot arrives later; do not reread that old snapshot as
// though the edited word had already disappeared.
export function afterApply<T extends { text: string }>(old: T[], index: number) {
  if (index < 0 || index >= old.length) return null;
  const count = old.length - 1;
  if (count <= 0) return null;
  const next = Math.min(index, count - 1);
  return { index: next, draft: old[next < index ? next : next + 1].text };
}
