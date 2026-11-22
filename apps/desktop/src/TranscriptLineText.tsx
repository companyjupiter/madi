import type { TranscriptLine } from './files';

type Props = {
  line: TranscriptLine;
  threshold: number;
  review: (lineId: string, wordIndex: number) => void;
};

function wordsMatchText(line: TranscriptLine) {
  return line.editedText === null || line.text === line.words.map((word, index) =>
    `${line.wordSpacing[index] ? ' ' : ''}${word.text}`).join('');
}

export function hasReviewLinks(line: TranscriptLine, threshold: number) {
  return wordsMatchText(line) && line.words.some(word => word.conf < threshold);
}

export function TranscriptLineText({ line, threshold, review }: Props) {
  // Whole-line edits retain the acoustic words for timing/review. Those words
  // no longer describe the displayed sentence, unlike an individual word edit.
  if (!wordsMatchText(line)) return <>{line.text}</>;
  return <>{line.words.map((word, index) => <span key={word.id}>
    {line.wordSpacing[index] ? ' ' : ''}
    {word.conf < threshold
      ? <button className="review-word" onClick={() => review(line.id, index)}>{word.text}</button>
      : word.text}
  </span>)}</>;
}
