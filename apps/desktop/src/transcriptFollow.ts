// Port of the shipping TranscriptFollowModel.swift. Geometry does not release
// follow: translated text, edits and regrouping can change it without a gesture.
export interface LineRef { id: string; end: number }
export type FollowAction = 'none' | 'pinToTail';

export class TranscriptFollow {
  following = true;
  atBottom = true;
  unseen = 0;
  seenTailID: string | null = null;
  seenTailEnd = -1;
  nearZone = 120;
  pinTolerance = 2;
  rearmZone = 160;
  wheelDeadband = 2;

  geometry(gap: number, isLive: boolean, lines: LineRef[]): FollowAction {
    this.atBottom = gap <= this.nearZone;
    if (this.atBottom) this.markSeen(lines);
    return this.following && isLive && gap > this.pinTolerance ? 'pinToTail' : 'none';
  }
  // Native positive delta means up; DOM wheel adapters invert their deltaY.
  userScrolled(deltaY: number, gap: number) {
    if (deltaY > this.wheelDeadband) this.following = false;
    else if (deltaY < -this.wheelDeadband && gap <= this.rearmZone) this.following = true;
  }
  programmaticJump() { this.following = false; }
  linesChanged(lines: LineRef[]) {
    if (!lines.length) { this.reset(); return; }
    if (this.atBottom || this.following) { this.markSeen(lines); return; }
    const index = this.seenTailID === null ? -1 : lines.findIndex(line => line.id.toLowerCase() === this.seenTailID);
    if (index >= 0) this.unseen = lines.length - index - 1;
    else if (this.seenTailEnd >= 0) this.unseen = lines.filter(line => line.end > this.seenTailEnd + .001).length;
    else this.markSeen(lines);
  }
  pillTapped(lines: LineRef[]): FollowAction {
    this.following = true;
    this.markSeen(lines);
    return 'pinToTail';
  }
  reset() {
    this.following = true;
    this.atBottom = true;
    this.unseen = 0;
    this.seenTailID = null;
    this.seenTailEnd = -1;
  }
  private markSeen(lines: LineRef[]) {
    this.unseen = 0;
    const last = lines.at(-1);
    if (last) { this.seenTailID = last.id.toLowerCase(); this.seenTailEnd = last.end; }
  }
}
