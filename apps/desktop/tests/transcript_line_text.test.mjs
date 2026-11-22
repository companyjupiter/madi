import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { resolve } from 'node:path';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';
import react from '@vitejs/plugin-react';

const server = await createServer({
  configFile: false,
  root: resolve(import.meta.dirname, '..'),
  plugins: [react()],
  server: { middlewareMode: true, ws: false },
  appType: 'custom',
});
after(() => server.close());
const { hasReviewLinks, TranscriptLineText } = await server.ssrLoadModule('/src/TranscriptLineText.tsx');
const words = [
  { id: 'first', text: 'Original', conf: .3 },
  { id: 'comma', text: ',', conf: 1 },
  { id: 'last', text: 'words', conf: 1 },
];
const line = { id: 'line', words, wordSpacing: [false, false, true], text: 'Original, words', editedText: null };
const render = value => renderToStaticMarkup(createElement(TranscriptLineText, { line: value, threshold: .55, review: () => {} }));

test('a whole-line correction replaces stale ASR words and their review links', () => {
  const edited = 'Corrected text. <Local & private>';
  const html = render({ ...line, text: edited, editedText: edited });
  assert.equal(html, 'Corrected text. &lt;Local &amp; private&gt;');
  assert.equal(hasReviewLinks({ ...line, text: edited, editedText: edited }, .55), false);
});

test('unedited ASR retains native punctuation spacing and low-confidence links', () => {
  const html = render(line);
  assert.equal(html, '<span><button class="review-word">Original</button></span><span>,</span><span> words</span>');
  assert.match(html, /<button class="review-word">Original<\/button>/);
  assert.equal((html.match(/<button/g) ?? []).length, 1);
});

test('an individual word correction keeps other words available for review', () => {
  const edited = 'Original, corrected';
  const value = { ...line, text: edited, editedText: edited, words: [...words.slice(0, 2), { ...words[2], text: 'corrected' }] };
  const html = render(value);
  assert.equal(html, '<span><button class="review-word">Original</button></span><span>,</span><span> corrected</span>');
  assert.match(html, /<button class="review-word">Original<\/button>/);
  assert.equal(hasReviewLinks(value, .55), true);
});
