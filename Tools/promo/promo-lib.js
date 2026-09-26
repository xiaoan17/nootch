// Helpers, sample data and shape paths for promo.js.
// Everything is a pure function of time so frames render deterministically.

const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, p) => a + (b - a) * p;
const prog = (t, a, b) => clamp((t - a) / (b - a));
const easeOut = p => 1 - Math.pow(1 - p, 3);
const easeInOut = p => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
// Damped spring approximating SwiftUI .spring(response: 0.4, dampingFraction: 0.86).
const spring = p => (p <= 0 ? 0 : p >= 1 ? 1 : 1 - Math.exp(-6 * p) * Math.cos(9 * p) * (1 - p));
const fadeIO = (t, a, b, d = 0.35) => Math.min(prog(t, a, a + d), 1 - prog(t, b - d, b));

// Formatters mirror NotchPanel.swift (compactCost / compactTokenCount / compactDuration).
function compactCost(c) {
  if (c >= 100) return '$' + Math.round(c);
  if (c >= 10) return '$' + c.toFixed(1);
  return '$' + c.toFixed(2);
}
function compactTokens(n) {
  let s, v;
  if (n >= 1e9) { v = n / 1e9; s = 'b'; } else if (n >= 1e6) { v = n / 1e6; s = 'm'; }
  else if (n >= 1e3) { v = n / 1e3; s = 'k'; } else return String(Math.round(n));
  return v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2) + s;
}
function compactDuration(sec) {
  const m = Math.floor(sec / 60);
  if (m < 60) return m + 'm';
  const h = Math.floor(m / 60);
  return m % 60 ? `${h}h ${m % 60}m` : `${h}h`;
}

// Sample values (not real usage). Model split is shared across windows.
const WINDOWS = [
  { key: '今日', cost: 82.2, tokens: 12.4e6, sessions: 23, active: 5 * 3600 + 12 * 60 },
  { key: '24h', cost: 96.4, tokens: 14.8e6, sessions: 27, active: 6 * 3600 + 5 * 60 },
  { key: '近 7 天', cost: 412.6, tokens: 63.5e6, sessions: 118, active: 31 * 3600 + 40 * 60 },
  { key: '近 30 天', cost: 1586.3, tokens: 248e6, sessions: 461, active: 122 * 3600 + 15 * 60 },
];
const MODELS = [
  { model: 'claude-opus-4-7', tok: 0.574, cost: 0.625 },
  { model: 'gpt-5-codex', tok: 0.231, cost: 0.181 },
  { model: 'kimi-k2', tok: 0.106, cost: 0.093 },
  { model: 'grok-code-fast-1', tok: 0.052, cost: 0.058 },
  { model: 'claude-sonnet-4-5', tok: 0.037, cost: 0.043 },
];
const mix = (a, b, p) => ({
  cost: lerp(a.cost, b.cost, p), tokens: lerp(a.tokens, b.tokens, p),
  sessions: lerp(a.sessions, b.sessions, p), active: lerp(a.active, b.active, p),
});

// RightEdgeNotchShape from NotchPanel.swift, as an SVG path string.
function railPath(w, h, flareW, flareH, corner) {
  const k = 0.5522847;
  const fh = Math.min(flareH, h * 0.35);
  const cr = Math.min(corner, Math.max(2, (h - 2 * fh) * 0.5));
  const fw = Math.min(flareW, Math.max(2, w * 0.45));
  return [
    `M${w},0`,
    `C${w},${fh * k} ${w - fw * (1 - k)},${fh} ${w - fw},${fh}`,
    `L${cr},${fh}`,
    `C${cr * (1 - k)},${fh} 0,${fh + cr * (1 - k)} 0,${fh + cr}`,
    `L0,${h - fh - cr}`,
    `C0,${h - fh - cr * (1 - k)} ${cr * (1 - k)},${h - fh} ${cr},${h - fh}`,
    `L${w - fw},${h - fh}`,
    `C${w - fw * (1 - k)},${h - fh} ${w},${h - fh * k} ${w},${h}`,
    'Z',
  ].join(' ');
}

// PopoverCalloutShape: rounded card with a beak on the right pointing at pointerY.
function calloutPath(w, h, pointerY, r = 16, pw = 10, ph = 9) {
  const cw = w - pw;
  const py = clamp(pointerY, r + ph, h - r - ph);
  return [
    `M${r},0 L${cw - r},0 A${r},${r} 0 0 1 ${cw},${r}`,
    `L${cw},${py - ph} L${w},${py} L${cw},${py + ph}`,
    `L${cw},${h - r} A${r},${r} 0 0 1 ${cw - r},${h}`,
    `L${r},${h} A${r},${r} 0 0 1 0,${h - r}`,
    `L0,${r} A${r},${r} 0 0 1 ${r},0 Z`,
  ].join(' ');
}
