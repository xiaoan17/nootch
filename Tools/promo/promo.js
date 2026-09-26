// Timeline for the nootch promo. window.renderFrame(t) draws the scene at t seconds.
// Stage is 960x540 logical points; the screen's right edge is x = 960.

const DURATION = 27;
const $ = id => document.getElementById(id);
const RAIL_TOP = 150;
const CARD_LEFT = 960 - 72 - 2 - 312;

// ---------- one-time DOM setup ----------
const rowsEl = $('rows');
const rowEls = [];
function addRow(label, cls) {
  const r = document.createElement('div');
  r.className = 'row ' + (cls || '');
  r.innerHTML = `<span class="m"></span><b></b>`;
  r.firstChild.textContent = label;
  rowsEl.appendChild(r);
  rowEls.push(r);
  return r;
}
const rowCost = addRow('Cost', 'main');
const rowTok = addRow('Tokens');
const rowSes = addRow('Sessions');
const modelRows = MODELS.map(m => {
  const r = addRow(m.model);
  const bar = document.createElement('div');
  bar.className = 'bar';
  bar.innerHTML = '<i></i>';
  rowsEl.appendChild(bar);
  r.bar = bar;
  return r;
});

const TOOLS = [
  { name: 'Claude Code', img: '../../Sources/Nootch/Resources/claude.svg' },
  { name: 'Codex', img: '../../Sources/Nootch/Resources/openai.svg' },
  { name: 'Kimi Code', glyph: 'K' },
  { name: 'Grok', img: '../../Sources/Nootch/Resources/grok.svg', invert: true },
  { name: 'Pi', glyph: 'π' },
];
const toolRow = document.querySelector('.tl-row');
const toolEls = TOOLS.map(tl => {
  const d = document.createElement('div');
  d.className = 'tool';
  const inner = tl.img
    ? `<img src="${tl.img}" style="${tl.invert ? 'filter:invert(1)' : ''}">`
    : `<span class="glyph">${tl.glyph}</span>`;
  d.innerHTML = `<div class="tile">${inner}</div><div class="name">${tl.name}</div>`;
  toolRow.appendChild(d);
  return d;
});
const TOOL_X = TOOLS.map((_, i) => 480 + (i - 2) * 152);
const flow = $('flow');
const flowPaths = TOOL_X.map(x => {
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  p.setAttribute('d', `M${x},268 C${x},310 480,300 480,338`);
  p.setAttribute('fill', 'none');
  p.setAttribute('stroke', 'rgba(126,231,135,.55)');
  p.setAttribute('stroke-width', '1.4');
  flow.appendChild(p);
  const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
  dot.setAttribute('r', '3');
  dot.setAttribute('fill', '#b9f5c1');
  flow.appendChild(dot);
  p.dot = dot;
  p.len = p.getTotalLength();
  return p;
});

const TERM = [
  { at: 0, cls: 'd', text: '~/projects/demo-app' },
  { at: 0.3, cls: 'p', text: '❯ claude', type: 10 },
  { at: 2.9, cls: 'o', text: '✻ Welcome to Claude Code' },
  { at: 3.3, cls: '', text: '> 给 UsageStore 加上按窗口聚合，并补充单测', type: 16 },
  { at: 5.4, cls: 'd', text: '⏺ Read UsageStore.swift (145 lines)' },
  { at: 7.2, cls: 'd', text: '⏺ Update 3 files  +128 −24' },
  { at: 9.0, cls: 'd', text: '⏺ Bash swift test --filter Usage' },
  { at: 10.6, cls: 'g', text: '✓ 42 tests passed' },
  { at: 12.2, cls: 'd', text: '⏺ Update UsageStore.swift  +36 −8' },
  { at: 14.4, cls: 'o', text: '✻ Thinking…' },
];

const CAPTIONS = [
  [2.9, 6.0, '屏幕边缘，常驻一个小圆点', '实时显示当前窗口的 AI 编码费用'],
  [6.0, 11.0, '悬停，展开详情卡', '费用 · Tokens · Sessions · 活跃时长 · Top 5 模型'],
  [11.0, 15.4, '费用窗口，随心切换', '今日 · 24h · 近 7 天 · 近 30 天'],
  [15.4, 19.0, '按住面板，拖到顺手的位置', '松手自动保存，左右边缘和底部居中都支持'],
];

// Cursor keyframes: [time, x, y]; eased between consecutive keys.
const SEG_X = i => CARD_LEFT + 14 + 35.5 + 71 * i;
const CURSOR = [
  [2.8, 470, 300], [3.3, 470, 300], [4.2, 950, 238], [5.9, 944, 236],
  [6.5, 913, 211], [11.2, 915, 212],
  [11.8, SEG_X(1), 'seg'], [12.4, SEG_X(1), 'seg'], [12.8, SEG_X(2), 'seg'],
  [13.4, SEG_X(2), 'seg'], [13.8, SEG_X(3), 'seg'], [14.4, SEG_X(3), 'seg'],
  [14.8, SEG_X(0), 'seg'], [15.3, SEG_X(0), 'seg'], [15.9, 930, 'grab'],
];
const CLICKS = [12.0, 13.0, 14.0, 15.0, 16.1];
const SWITCHES = [[12.0, 1], [13.0, 2], [14.0, 3], [15.0, 0]];

function railOffset(t) {
  const up = easeInOut(prog(t, 16.25, 17.0)) * -90;
  const down = easeInOut(prog(t, 17.1, 18.0)) * 200;
  return up + down;
}

function stats(t) {
  let cur = mix(WINDOWS[0], WINDOWS[0], 0);
  let idx = 0;
  for (const [at, to] of SWITCHES) {
    if (t >= at) { cur = mix(cur, WINDOWS[to], easeOut(prog(t, at, at + 0.6))); idx = to; }
  }
  return { cur, idx };
}

// ---------- per-frame render ----------
function setOpacity(el, o) { el.style.opacity = o.toFixed(3); el.style.visibility = o <= 0.001 ? 'hidden' : 'visible'; }

function renderTerm(t) {
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  let html = '';
  let last = -1;
  TERM.forEach((l, i) => { if (t >= l.at) last = i; });
  TERM.forEach((l, i) => {
    if (t < l.at) return;
    const chars = [...l.text];
    const n = l.type ? Math.min(chars.length, Math.floor((t - l.at) * l.type)) : chars.length;
    const caret = i === last && Math.floor(t * 2) % 2 === 0 ? '<span class="c"> </span>' : '';
    html += `<span class="${l.cls}">${esc(chars.slice(0, n).join(''))}</span>${caret}\n`;
  });
  $('termtext').innerHTML = html;
}

function renderPanel(t, top) {
  const e = spring(prog(t, 4.2, 4.85));
  const w = lerp(20, 72, e), h = lerp(64, 172, e);
  const y = top + 86 - h / 2;
  const panel = $('panel');
  panel.style.top = y + 'px';
  panel.style.width = w + 'px';
  panel.style.height = h + 'px';
  const d = railPath(w, h, 24 * e, 36 * e, lerp(8, 28, e));
  $('railGlass').style.clipPath = `path('${d}')`;
  const sv = $('railStroke');
  sv.setAttribute('width', w); sv.setAttribute('height', h);
  sv.firstChild.setAttribute('d', d);
  setOpacity(panel, prog(t, 2.6, 3.0));

  const tab = $('tabDot');
  tab.style.left = (w - 10) + 'px'; tab.style.top = '8px';
  setOpacity(tab, 1 - prog(t, 4.2, 4.4));

  const item = $('railItem');
  const ie = clamp(e * 1.15);
  item.style.top = (48 + (h - 172) / 2 + 36 * (1 - e)) + 'px';
  item.style.transform = `scale(${lerp(0.85, 1, ie)})`;
  setOpacity(item, prog(t, 4.3, 4.6));
  const hover = prog(t, 6.3, 6.5) * (1 - prog(t, 15.3, 15.5));
  $('gauge').style.transform = `scale(${1 + 0.06 * hover})`;

  const { cur } = stats(t);
  const intro = easeOut(prog(t, 4.4, 5.8));
  $('dotLabel').textContent = compactCost(cur.cost * intro);
}

function renderCard(t, gaugeY) {
  const { cur, idx } = stats(t);
  const roll = easeOut(prog(t, 6.75, 8.4));
  const v = { cost: cur.cost * roll, tokens: cur.tokens * roll, sessions: cur.sessions * roll, active: cur.active * roll };
  $('secTitle').textContent = WINDOWS[idx].key + '用量';
  rowCost.lastChild.textContent = '$' + v.cost.toFixed(2);
  rowTok.lastChild.textContent = compactTokens(v.tokens);
  rowSes.lastChild.textContent = `${Math.round(v.sessions)} · ${compactDuration(v.active)}`;
  modelRows.forEach((r, i) => {
    const m = MODELS[i];
    r.lastChild.textContent = `${compactTokens(v.tokens * m.tok)} · $${(v.cost * m.cost).toFixed(2)}`;
    r.bar.firstChild.style.width = (m.cost / MODELS[0].cost * 100 * roll).toFixed(1) + '%';
  });
  rowEls.forEach((r, i) => {
    const o = easeOut(prog(t, 6.7 + i * 0.06, 7.0 + i * 0.06));
    r.style.opacity = o; r.style.transform = `translateX(${(1 - o) * 8}px)`;
    if (r.bar) r.bar.style.opacity = o;
  });

  const card = $('card');
  const h = card.offsetHeight;
  const top = clamp(gaugeY - 70, 130, 540 - h - 12);
  card.style.left = CARD_LEFT + 'px';
  card.style.top = top + 'px';
  const d = calloutPath(312, h, gaugeY - top);
  $('cardGlass').style.clipPath = `path('${d}')`;
  const sv = $('cardStroke');
  sv.setAttribute('width', 312); sv.setAttribute('height', h);
  sv.firstChild.setAttribute('d', d);
  const show = easeOut(prog(t, 6.55, 6.85)) * (1 - prog(t, 15.35, 15.65));
  setOpacity(card, show);
  card.style.transform = `scale(${lerp(0.94, 1, show)})`;
  $('live').style.opacity = 0.55 + 0.45 * Math.abs(Math.cos(t * 2.4));
  return top;
}

function renderSeg(t, cardTop) {
  const seg = $('seg');
  const segTop = cardTop - 76;
  seg.style.left = CARD_LEFT + 'px';
  seg.style.top = segTop + 'px';
  const o = easeOut(prog(t, 11.0, 11.35)) * (1 - prog(t, 15.35, 15.65));
  setOpacity(seg, o);
  seg.style.transform = `translateY(${(1 - o) * -8}px)`;
  let pos = 0, idx = 0;
  for (const [at, to] of SWITCHES) {
    if (t >= at) { pos = lerp(pos, to, spring(prog(t, at, at + 0.35))); idx = to; }
  }
  const thumb = $('segThumb');
  thumb.style.left = (2 + pos * 71) + 'px';
  thumb.style.width = '71px';
  [...seg.querySelectorAll('.seg-track span')].forEach((s, i) => s.classList.toggle('on', i === idx));
  return segTop + 10 + 18 + 13; // vertical centre of the segmented track
}

function renderCursor(t, segY, grabY) {
  const c = $('cursor');
  const resolve = y => (y === 'seg' ? segY : y === 'grab' ? grabY : y);
  let x = CURSOR[0][1], y = resolve(CURSOR[0][2]);
  for (let i = 1; i < CURSOR.length; i++) {
    const [t0, x0, y0] = CURSOR[i - 1], [t1, x1, y1] = CURSOR[i];
    if (t >= t0) {
      const p = easeInOut(prog(t, t0, t1));
      x = lerp(x0, x1, p); y = lerp(resolve(y0), resolve(y1), p);
    }
  }
  if (t >= 15.9) y = grabY; // follow the rail while dragging
  c.style.transform = `translate(${x - 6}px, ${y - 3}px)`;
  setOpacity(c, prog(t, 2.8, 3.1) * (1 - prog(t, 18.7, 19.0)));
  let rs = 0, ro = 0, press = 0;
  for (const at of CLICKS) {
    const p = prog(t, at, at + 0.45);
    if (p > 0 && p < 1) { rs = 0.3 + p; ro = 1 - p; }
  }
  if (t >= 16.1 && t < 18.2) press = 1;
  c.style.setProperty('--rs', rs.toFixed(3));
  c.style.setProperty('--ro', ro.toFixed(3));
  c.firstChild.style.transform = `scale(${1 - 0.12 * press})`;
}

function renderCaption(t) {
  const el = $('caption');
  let o = 0;
  for (const [a, b, title, sub] of CAPTIONS) {
    if (t >= a && t < b) {
      o = fadeIO(t, a, b, 0.4);
      el.firstChild.textContent = title;
      el.lastChild.textContent = sub;
      el.style.transform = `translateY(${(1 - easeOut(prog(t, a, a + 0.5))) * 14}px)`;
    }
  }
  setOpacity(el, o);
}

function renderIntro(t) {
  setOpacity($('intro'), 1 - prog(t, 2.3, 2.9));
  const a = easeOut(prog(t, 0.3, 1.0)), b = easeOut(prog(t, 0.9, 1.6));
  const it = document.querySelector('.i-t'), is = document.querySelector('.i-s');
  it.style.opacity = a; it.style.transform = `translateY(${(1 - a) * 18}px)`;
  is.style.opacity = b; is.style.transform = `translateY(${(1 - b) * 14}px)`;
}

function renderTools(t) {
  setOpacity($('tools'), prog(t, 19.0, 19.4));
  const title = document.querySelector('.tl-title');
  const ta = easeOut(prog(t, 19.1, 19.6));
  title.style.opacity = ta; title.style.transform = `translateY(${(1 - ta) * 12}px)`;
  toolEls.forEach((el, i) => {
    const p = spring(prog(t, 19.3 + i * 0.12, 19.9 + i * 0.12));
    el.style.opacity = clamp(p * 1.5);
    el.style.transform = `translateY(${(1 - p) * 26}px) scale(${lerp(0.9, 1, p)})`;
  });
  flowPaths.forEach((p, i) => {
    const draw = easeInOut(prog(t, 20.0 + i * 0.05, 20.7 + i * 0.05));
    p.setAttribute('stroke-dasharray', p.len);
    p.setAttribute('stroke-dashoffset', (p.len * (1 - draw)).toFixed(2));
    const phase = ((t - 20.7 - i * 0.17) / 1.1) % 1;
    const pt = p.getPointAtLength(p.len * (phase < 0 ? 0 : phase));
    p.dot.setAttribute('cx', pt.x); p.dot.setAttribute('cy', pt.y);
    p.dot.setAttribute('opacity', t > 20.7 + i * 0.17 ? Math.sin(Math.PI * phase).toFixed(3) : 0);
  });
  const eo = easeOut(prog(t, 20.5, 21.0));
  const eng = $('engine');
  eng.style.opacity = eo;
  eng.style.transform = `translateX(-50%) scale(${lerp(0.92, 1, eo)})`;
  document.querySelectorAll('.tl-badges span').forEach((s, i) => {
    const p = easeOut(prog(t, 21.2 + i * 0.15, 21.6 + i * 0.15));
    s.style.opacity = p; s.style.transform = `translateY(${(1 - p) * 10}px)`;
  });
}

function renderOutro(t) {
  setOpacity($('outro'), easeInOut(prog(t, 23.0, 23.5)));
  const i = spring(prog(t, 23.2, 24.0));
  const icon = $('oIcon');
  icon.style.opacity = clamp(i * 1.6);
  icon.style.transform = `scale(${lerp(0.6, 1, i)})`;
  [['oName', 23.55], ['oSlogan', 23.85], ['oUrl', 24.15]].forEach(([id, at]) => {
    const p = easeOut(prog(t, at, at + 0.5));
    $(id).style.opacity = p;
    $(id).style.transform = `translateY(${(1 - p) * 14}px)`;
  });
}

window.renderFrame = function (t) {
  $('fade').style.opacity = Math.max(1 - prog(t, 0, 0.45), prog(t, DURATION - 0.5, DURATION)).toFixed(3);
  renderIntro(t);
  renderTerm(t);
  const top = RAIL_TOP + railOffset(t);
  renderPanel(t, top);
  const gaugeY = top + 75;
  const cardTop = renderCard(t, gaugeY);
  const segY = renderSeg(t, cardTop);
  renderCaption(t);
  const tt = $('toast');
  tt.style.left = (960 - 72 - 14 - 90) + 'px';
  tt.style.top = (gaugeY - 12) + 'px';
  setOpacity(tt, fadeIO(t, 18.3, 19.0, 0.2));
  renderCursor(t, segY, top + 40);
  renderTools(t);
  renderOutro(t);
};
window.PROMO_DURATION = DURATION;

// Preview in a browser: open promo.html#12.5 to see t = 12.5s, or #play to loop.
(function preview() {
  const h = location.hash.slice(1);
  if (h === 'play') {
    const start = performance.now();
    const tick = now => { renderFrame(((now - start) / 1000) % DURATION); requestAnimationFrame(tick); };
    requestAnimationFrame(tick);
  } else {
    renderFrame(parseFloat(h) || 0);
  }
})();
