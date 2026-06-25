#!/usr/bin/env node
// build_index.mjs — generate a self-contained docs/manual/index.html from the
// per-section Markdown in ko/ and en/. The Markdown is rendered to HTML at BUILD
// time and embedded inline, so index.html works fully offline (file://) with no
// fetch/CORS and no client-side Markdown library. Re-run after editing any .md:
//     node docs/manual/build_index.mjs
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const LANGS = [
  { code: 'ko', label: '한국어' },
  { code: 'en', label: 'English' },
];

// ── minimal, dependency-free Markdown → HTML (enough for a manual) ──
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
function inline(s) {
  let out = esc(s);
  out = out.replace(/`([^`]+)`/g, (_, c) => `<code>${c}</code>`);
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');
  return out;
}
const slug = (s) => s.toLowerCase().replace(/[^\w가-힣]+/g, '-').replace(/(^-|-$)/g, '');

function render(md) {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const html = [];
  let i = 0;
  let listStack = []; // {tag}
  const closeLists = (toDepth = 0) => { while (listStack.length > toDepth) html.push(`</${listStack.pop()}>`); };
  let para = [];
  const flushPara = () => { if (para.length) { html.push(`<p>${inline(para.join(' '))}</p>`); para = []; } };

  while (i < lines.length) {
    const line = lines[i];
    // fenced code
    if (/^```/.test(line)) {
      flushPara(); closeLists();
      const buf = []; i++;
      while (i < lines.length && !/^```/.test(lines[i])) { buf.push(esc(lines[i])); i++; }
      i++; html.push(`<pre><code>${buf.join('\n')}</code></pre>`); continue;
    }
    // table (header row | --- separator)
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1])) {
      flushPara(); closeLists();
      const cells = (r) => r.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
      const head = cells(line);
      i += 2;
      const rows = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) { rows.push(cells(lines[i])); i++; }
      html.push('<table><thead><tr>' + head.map((c) => `<th>${inline(c)}</th>`).join('') + '</tr></thead><tbody>'
        + rows.map((r) => '<tr>' + r.map((c) => `<td>${inline(c)}</td>`).join('') + '</tr>').join('') + '</tbody></table>');
      continue;
    }
    // headings
    let m = /^(#{1,4})\s+(.*)$/.exec(line);
    if (m) {
      flushPara(); closeLists();
      const lvl = m[1].length, txt = m[2].trim();
      const id = lvl === 1 ? null : ` id="${slug(txt)}"`;
      html.push(`<h${lvl}${id || ''}>${inline(txt)}</h${lvl}>`); i++; continue;
    }
    // hr
    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) { flushPara(); closeLists(); html.push('<hr>'); i++; continue; }
    // blockquote
    if (/^\s*>\s?/.test(line)) {
      flushPara(); closeLists();
      const buf = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^\s*>\s?/, '')); i++; }
      html.push(`<blockquote>${inline(buf.join(' '))}</blockquote>`); continue;
    }
    // list item (ordered / unordered), 2-space indent = nesting
    m = /^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(line);
    if (m) {
      flushPara();
      const depth = Math.floor(m[1].length / 2) + 1;
      const tag = /\d+\./.test(m[2]) ? 'ol' : 'ul';
      while (listStack.length < depth) { html.push(`<${tag}>`); listStack.push(tag); }
      while (listStack.length > depth) html.push(`</${listStack.pop()}>`);
      html.push(`<li>${inline(m[3])}</li>`); i++; continue;
    }
    // blank
    if (/^\s*$/.test(line)) { flushPara(); closeLists(); i++; continue; }
    // paragraph text
    para.push(line.trim()); i++;
  }
  flushPara(); closeLists();
  return html.join('\n');
}

// ── load sections per language ──
function sections(lang) {
  const dir = join(HERE, lang);
  return readdirSync(dir).filter((f) => f.endsWith('.md')).sort().map((f) => {
    const md = readFileSync(join(dir, f), 'utf8');
    const h1 = (/^#\s+(.*)$/m.exec(md) || [, f])[1].trim();
    const id = f.replace(/\.md$/, '');
    // drop the H1 from body (it becomes the section header we render ourselves)
    const body = render(md.replace(/^#\s+.*$/m, '').trim());
    return { id, title: h1, body };
  });
}

const data = Object.fromEntries(LANGS.map((l) => [l.code, sections(l.code)]));

const UI = {
  ko: { brand: 'Madi 사용자 매뉴얼', tagline: '온디바이스 회의 인텔리전스', toc: '목차', foot: '모든 처리는 이 Mac에서 — 전사·번역·요약이 기기를 떠나지 않습니다.' },
  en: { brand: 'Madi User Manual', tagline: 'On-device meeting intelligence', toc: 'Contents', foot: 'Everything runs on this Mac — transcripts, translation and summaries never leave the device.' },
};

const navFor = (lang) => data[lang].map((s, n) =>
  `<a class="nav-link" data-target="${lang}-${s.id}">` +
  `<span class="nav-num">${String(n + 1).padStart(2, '0')}</span>${esc(s.title)}</a>`).join('\n');

const sectionsFor = (lang) => data[lang].map((s, n) =>
  `<section id="${lang}-${s.id}" class="doc">` +
  `<div class="doc-num">${String(n + 1).padStart(2, '0')}</div>` +
  `<h1 class="doc-title">${esc(s.title)}</h1>${s.body}</section>`).join('\n');

const langPanes = LANGS.map((l) =>
  `<div class="lang-pane" data-lang="${l.code}"${l.code === 'ko' ? '' : ' hidden'}>` +
  `<nav class="toc"><div class="toc-h">${UI[l.code].toc}</div>${navFor(l.code)}</nav>` +
  `<main class="content">${sectionsFor(l.code)}<footer class="foot">${UI[l.code].foot}</footer></main></div>`).join('\n');

const langButtons = LANGS.map((l) =>
  `<button class="lang-btn${l.code === 'ko' ? ' on' : ''}" data-lang="${l.code}">${l.label}</button>`).join('');

const HTML = `<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Madi — 사용자 매뉴얼 / User Manual</title>
<style>
  :root{
    --bg:#fbfbfd; --panel:#fff; --ink:#1d1d22; --ink2:#5b5b66; --ink3:#8a8a96;
    --line:#e7e7ee; --accent:#4f46e5; --accent-soft:#eef0fe; --code:#f3f3f8;
    --maxw:780px;
  }
  @media (prefers-color-scheme:dark){:root{
    --bg:#161619; --panel:#1d1d22; --ink:#ececf1; --ink2:#a9a9b4; --ink3:#74747e;
    --line:#2c2c34; --accent:#8b85ff; --accent-soft:#23233a; --code:#24242b;
  }}
  *{box-sizing:border-box}
  html,body{margin:0;background:var(--bg);color:var(--ink);
    font:15px/1.7 -apple-system,BlinkMacSystemFont,"Pretendard","Apple SD Gothic Neo","Segoe UI",sans-serif;}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}
  .wrap{display:flex;min-height:100vh}
  .panes{flex:1;min-width:0}
  /* the per-pane .toc exists only to be cloned into the sidebar — hide the in-flow copy */
  .lang-pane>.toc{display:none}
  /* sidebar */
  .side{position:sticky;top:0;height:100vh;width:288px;flex:0 0 288px;overflow-y:auto;
    background:var(--panel);border-right:1px solid var(--line);padding:26px 18px 40px}
  .brand{display:flex;align-items:baseline;gap:8px;padding:0 8px 2px}
  .brand b{font-size:18px;letter-spacing:-.2px}
  .brand .dot{width:8px;height:8px;border-radius:50%;background:var(--accent);align-self:center}
  .tag{padding:0 8px 18px;color:var(--ink3);font-size:12.5px}
  .langbar{display:flex;gap:6px;padding:0 8px 16px}
  .lang-btn{flex:1;padding:7px 0;border:1px solid var(--line);background:transparent;color:var(--ink2);
    border-radius:9px;font-size:13px;cursor:pointer;transition:.15s}
  .lang-btn.on{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
  .toc-h{padding:6px 8px;color:var(--ink3);font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase}
  .nav-link{display:flex;align-items:center;gap:10px;padding:7px 9px;border-radius:8px;color:var(--ink2);
    font-size:13.5px;cursor:pointer}
  .nav-link:hover{background:var(--accent-soft);text-decoration:none;color:var(--ink)}
  .nav-link.active{background:var(--accent-soft);color:var(--accent);font-weight:600}
  .nav-num{color:var(--ink3);font-size:11px;font-variant-numeric:tabular-nums;min-width:16px}
  .nav-link.active .nav-num{color:var(--accent)}
  /* content */
  .content{flex:1;min-width:0;padding:0}
  .doc{max-width:var(--maxw);margin:0 auto;padding:64px 40px 40px}
  .doc-num{color:var(--accent);font-weight:700;font-size:12px;letter-spacing:.1em}
  .doc-title{font-size:30px;line-height:1.2;letter-spacing:-.4px;margin:6px 0 26px;padding-bottom:18px;border-bottom:1px solid var(--line)}
  .doc h2{font-size:21px;margin:38px 0 12px;letter-spacing:-.2px}
  .doc h3{font-size:16.5px;margin:26px 0 8px;color:var(--ink)}
  .doc h4{font-size:14px;margin:20px 0 6px;color:var(--ink2);text-transform:uppercase;letter-spacing:.05em}
  .doc p{margin:12px 0;color:var(--ink)}
  .doc ul,.doc ol{margin:12px 0;padding-left:22px}
  .doc li{margin:6px 0}
  .doc li>ul,.doc li>ol{margin:6px 0}
  .doc strong{font-weight:650}
  .doc code{background:var(--code);border-radius:5px;padding:.12em .42em;font-size:.88em;
    font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
  .doc pre{background:var(--code);border:1px solid var(--line);border-radius:11px;padding:14px 16px;overflow:auto;margin:16px 0}
  .doc pre code{background:none;padding:0}
  .doc blockquote{margin:16px 0;padding:10px 16px;border-left:3px solid var(--accent);
    background:var(--accent-soft);border-radius:0 8px 8px 0;color:var(--ink2)}
  .doc table{border-collapse:collapse;width:100%;margin:16px 0;font-size:13.5px}
  .doc th,.doc td{border:1px solid var(--line);padding:8px 11px;text-align:left;vertical-align:top}
  .doc th{background:var(--accent-soft);font-weight:650}
  .doc hr{border:none;border-top:1px solid var(--line);margin:30px 0}
  .foot{max-width:var(--maxw);margin:10px auto 60px;padding:22px 40px 0;border-top:1px solid var(--line);
    color:var(--ink3);font-size:12.5px}
  @media (max-width:820px){
    .wrap{flex-direction:column}
    .side{position:static;width:auto;height:auto;border-right:none;border-bottom:1px solid var(--line)}
    .doc{padding:40px 22px 30px}
  }
</style>
</head>
<body>
<div class="wrap">
  <aside class="side">
    <div class="brand"><span class="dot"></span><b>Madi</b></div>
    <div class="tag" data-tag></div>
    <div class="langbar">${langButtons}</div>
    <div class="toc-host"></div>
  </aside>
  <div class="panes">${langPanes}</div>
</div>
<script>
  var TAG={ko:'온디바이스 회의 인텔리전스',en:'On-device meeting intelligence'};
  var panes=[].slice.call(document.querySelectorAll('.lang-pane'));
  var host=document.querySelector('.toc-host');
  var tagEl=document.querySelector('[data-tag]');
  function activate(lang){
    document.documentElement.lang=lang;
    tagEl.textContent=TAG[lang]||'';
    panes.forEach(function(p){ p.hidden = p.getAttribute('data-lang')!==lang; });
    document.querySelectorAll('.lang-btn').forEach(function(b){ b.classList.toggle('on', b.getAttribute('data-lang')===lang); });
    var pane=panes.filter(function(p){return p.getAttribute('data-lang')===lang;})[0];
    host.innerHTML=''; if(pane){ host.appendChild(pane.querySelector('.toc').cloneNode(true)); }
    wireNav();
    window.scrollTo(0,0);
  }
  function wireNav(){
    document.querySelectorAll('.toc-host .nav-link').forEach(function(a){
      a.addEventListener('click',function(){
        var el=document.getElementById(a.getAttribute('data-target'));
        if(el) el.scrollIntoView({behavior:'smooth',block:'start'});
      });
    });
  }
  document.querySelectorAll('.lang-btn').forEach(function(b){
    b.addEventListener('click',function(){ activate(b.getAttribute('data-lang')); });
  });
  // scroll-spy: highlight the section in view
  var spy;
  function startSpy(){
    if(spy) spy.disconnect();
    spy=new IntersectionObserver(function(es){
      es.forEach(function(e){
        if(e.isIntersecting){
          var id=e.target.id;
          document.querySelectorAll('.toc-host .nav-link').forEach(function(a){
            a.classList.toggle('active', a.getAttribute('data-target')===id);
          });
        }
      });
    },{rootMargin:'-10% 0px -80% 0px'});
    document.querySelectorAll('.lang-pane:not([hidden]) .doc').forEach(function(s){ spy.observe(s); });
  }
  var _act=activate; activate=function(l){_act(l);startSpy();};
  activate('ko');
</script>
</body>
</html>`;

writeFileSync(join(HERE, 'index.html'), HTML);
const kb = (Buffer.byteLength(HTML) / 1024).toFixed(0);
console.log(`index.html written (${kb} KB, ${data.ko.length} sections × ${LANGS.length} langs, self-contained)`);
