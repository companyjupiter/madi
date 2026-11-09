import { readFileSync } from 'node:fs';
import { TranscriptFollow } from '../../apps/desktop/src/transcriptFollow.ts';

const cases = JSON.parse(readFileSync(0, 'utf8'));
const result = cases.map(input => {
  const model = new TranscriptFollow();
  Object.assign(model, input.settings ?? {});
  return input.operations.map(operation => {
    let action = 'none';
    const lines = operation.lines ?? [];
    switch (operation.kind) {
      case 'geometry': action = model.geometry(operation.gap, operation.live, lines); break;
      case 'wheel': model.userScrolled(operation.delta, operation.gap); break;
      case 'jump': model.programmaticJump(); break;
      case 'lines': model.linesChanged(lines); break;
      case 'pill': action = model.pillTapped(lines); break;
      case 'reset': model.reset(); break;
      default: throw new Error('unknown operation');
    }
    return { action, following: model.following, atBottom: model.atBottom, unseen: model.unseen, seenTailID: model.seenTailID, seenTailEnd: model.seenTailEnd };
  });
});
process.stdout.write(JSON.stringify(result));
