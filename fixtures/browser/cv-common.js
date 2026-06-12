// hyperbench canvas fixtures — shared scaffolding.
// Layouts are seeded from the URL (?seed=N) so positions are stable within a
// run but not memorizable from the repo. Ground truth and interactions are
// recorded in window.__cv, which verifiers read over CDP. Coordinates in
// __cv are CANVAS-LOCAL CSS pixels; __cv.rect maps them to page space.
//
// Note for oracle/verifier authors: fixture top-level const/let are global
// lexical bindings that persist across Runtime.evaluate calls in the same
// context — wrap your evals in an IIFE or redeclarations will collide.

window.__cv = {
  seed: null,       // the seed actually used
  expect: {},       // per-fixture ground truth (positions, target values)
  clicks: [],       // every pointer-down on the canvas, canvas-local coords
  result: {},       // per-fixture outcome (hit, value, connected, dropped)
  rect: null,       // canvas.getBoundingClientRect() snapshot
};

// mulberry32 — tiny deterministic PRNG, good enough for layout jitter.
function cvRng() {
  const p = new URLSearchParams(location.search);
  let s = (parseInt(p.get('seed'), 10) || 1) >>> 0;
  window.__cv.seed = s;
  return function () {
    s |= 0; s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Wire a canvas: snapshot its rect (and keep it fresh on resize) and record
// every pointerdown in canvas-local coordinates.
function cvWire(canvas, onDown) {
  const snap = () => { window.__cv.rect = canvas.getBoundingClientRect().toJSON(); };
  snap();
  addEventListener('resize', snap);
  canvas.addEventListener('pointerdown', (e) => {
    const r = canvas.getBoundingClientRect();
    const pt = { x: e.clientX - r.left, y: e.clientY - r.top };
    window.__cv.clicks.push(pt);
    onDown && onDown(pt, e);
  });
}

function cvDist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }
