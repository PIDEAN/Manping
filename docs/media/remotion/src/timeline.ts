// Turns a recording timeline (docs/media/.out/<scene>.json, written by ../record.swift) into everything the
// animation needs per moment: which frame of which window shows, where the windows sit on the canvas, the
// pointer, clicks, camera moves, key presses and captions. Times in ms; positions in global screen points
// (top-left origin) unless they say canvas.
import { Easing } from 'remotion';

export const FPS = 25;
export const W = 1280;
export const H = 800;
/** The canvas area the recorded windows are fitted into; the caption capsule sits below it. */
export const STAGE = { x: 44, y: 30, w: 1192, h: 668 };
/** Centre line of the caption capsule. */
export const CAPTION_Y = 748;

export const T = { zoomIn: 640, zoomOut: 520, caption: 260, keys: 1300, windowFade: 180, loop: 500 };

export interface Box { x: number; y: number; w: number; h: number }
export interface Pt { x: number; y: number }

/** A window's place on screen from `t` on (the recorder writes a sample whenever it changes). */
export interface Bounds extends Box { t: number }
/** A run of recorded frames at the composition's frame rate: frame k shows `start + k × 40 ms`. */
export interface Segment { start: number; count: number; dir: string; digits?: number }
/** A still frame from `t` on (hand-made timelines and tests). */
export interface Still { t: number; img: string }
export interface WindowTrack {
  id: string;
  /** Visible from / until (ms). Windows that open or close mid-scene fade in thirds. */
  from: number;
  to: number;
  /** Stacking order (higher is in front). The recorder orders by window layer, then by first appearance. */
  z?: number;
  segments?: Segment[];
  stills?: Still[];
  bounds: Bounds[];
  /** Transparent margin in points around the window inside each image (a screenshot taken with its shadow). */
  margin?: { l: number; t: number; r: number; b: number };
  /** Draw a soft window shadow (off for images that already carry one). */
  shadow?: boolean;
}

export type SceneEvent =
  | { t: number; type: 'caption'; text: string }
  /** The pointer travels to (x, y), arriving at t + dur. */
  | { t: number; type: 'move'; x: number; y: number; dur?: number }
  /** A press at the pointer's position. */
  | { t: number; type: 'click' }
  /** The pointer holds `window` at (dx, dy) from its top-left corner until `until`. */
  | { t: number; type: 'drag'; window: string; dx: number; dy: number; until: number }
  /** The camera frames this box from t (arriving after T.zoomIn) and returns by `until`. */
  | { t: number; type: 'zoom'; x: number; y: number; w: number; h: number; until: number }
  | { t: number; type: 'keys'; keys: string[] }
  | { t: number; type: 'pointer'; visible: boolean };

export interface SceneData {
  scene: string;
  title?: string;
  /** Length of the recording (ms). */
  duration: number;
  windows: WindowTrack[];
  events: SceneEvent[];
  /** The screen area to fit into the stage; the union of all windows when absent. */
  stage?: Box;
}

/** Global points → canvas pixels. */
export interface Fit { s: number; ox: number; oy: number }

/** Camera: content point (fx, fy) is drawn at canvas point (sx, sy), scaled by s. */
export interface Cam { s: number; fx: number; fy: number; sx: number; sy: number }
export const NO_CAM: Cam = { s: 1, fx: STAGE.x + STAGE.w / 2, fy: STAGE.y + STAGE.h / 2, sx: STAGE.x + STAGE.w / 2, sy: STAGE.y + STAGE.h / 2 };

interface Leg { from: Pt; to: Pt; start: number; end: number }

export interface Timeline {
  data: SceneData;
  fit: Fit;
  /** When the loop fade back to the opening frame starts. */
  loopAt: number;
  total: number;
  windows: WindowTrack[];
  captions: { text: string; at: number }[];
  cams: { t: number; cam: Cam }[];
  legs: Leg[];
  clicks: number[];
  drags: Extract<SceneEvent, { type: 'drag' }>[];
  keys: Extract<SceneEvent, { type: 'keys' }>[];
  pointer: { from: number; to: number }[];
}

export const clamp = (v: number, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
export const ease = Easing.bezier(0.65, 0, 0.35, 1);
const glide = Easing.bezier(0.45, 0, 0.2, 1);

/** Where a window is at `t` (its last bounds sample at or before t). */
export function boundsAt(w: WindowTrack, t: number): Bounds {
  let b = w.bounds[0]!;
  for (const s of w.bounds) if (s.t <= t) b = s;
  return b;
}

/** Frame source for a window at `t`, or null before its first frame. */
export function frameAt(w: WindowTrack, t: number): string | null {
  if (w.stills?.length) {
    let img: string | null = null;
    for (const s of w.stills) if (s.t <= t) img = s.img;
    return img ?? w.stills[0]!.img;
  }
  let seg: Segment | undefined;
  for (const s of w.segments ?? []) if (s.start <= t) seg = s;
  seg ??= w.segments?.[0];
  if (!seg || seg.count <= 0) return null;
  const k = Math.min(seg.count - 1, Math.max(0, Math.floor(((t - seg.start) * FPS) / 1000)));
  return `${seg.dir}/${String(k).padStart(seg.digits ?? 5, '0')}.png`;
}

function union(boxes: Box[]): Box {
  const x0 = Math.min(...boxes.map((b) => b.x));
  const y0 = Math.min(...boxes.map((b) => b.y));
  const x1 = Math.max(...boxes.map((b) => b.x + b.w));
  const y1 = Math.max(...boxes.map((b) => b.y + b.h));
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

export function fitStage(data: SceneData): Fit {
  const box = data.stage ?? union(data.windows.flatMap((w) => w.bounds));
  const s = Math.min(STAGE.w / box.w, STAGE.h / box.h);
  return { s, ox: STAGE.x + (STAGE.w - box.w * s) / 2 - box.x * s, oy: STAGE.y + (STAGE.h - box.h * s) / 2 - box.y * s };
}

export const toCanvas = (f: Fit, p: Pt): Pt => ({ x: f.ox + p.x * f.s, y: f.oy + p.y * f.s });
export const boxToCanvas = (f: Fit, b: Box): Box => ({ ...toCanvas(f, b), w: b.w * f.s, h: b.h * f.s });

/** Frame a canvas box in the stage (at most 2×), keeping the view on the stage. */
export function zoomCam(box: Box): Cam {
  const s = clamp(Math.min((STAGE.w * 0.9) / box.w, (STAGE.h * 0.9) / box.h), 1, 2);
  const hw = STAGE.w / s / 2;
  const hh = STAGE.h / s / 2;
  const fit = (v: number, lo: number, hi: number, half: number) => (hi - lo <= half * 2 ? (lo + hi) / 2 : clamp(v, lo + half, hi - half));
  return {
    s,
    fx: fit(box.x + box.w / 2, STAGE.x, STAGE.x + STAGE.w, hw),
    fy: fit(box.y + box.h / 2, STAGE.y, STAGE.y + STAGE.h, hh),
    sx: NO_CAM.sx,
    sy: NO_CAM.sy,
  };
}

export function build(data: SceneData): Timeline {
  const fit = fitStage(data);
  const events = [...data.events].sort((a, b) => a.t - b.t);
  const loopAt = data.duration;
  const total = loopAt + T.loop;
  const windows = [...data.windows].sort((a, b) => (a.z ?? 0) - (b.z ?? 0));

  const captions: Timeline['captions'] = [];
  for (const e of events) {
    if (e.type !== 'caption' || e.text === captions.at(-1)?.text) continue;
    captions.push({ text: e.text, at: captions.length ? e.t : 0 });
  }

  const cams: Timeline['cams'] = [{ t: 0, cam: NO_CAM }];
  for (const e of events) {
    if (e.type !== 'zoom') continue;
    const cam = zoomCam(boxToCanvas(fit, e));
    cams.push({ t: e.t, cam: NO_CAM }, { t: e.t + T.zoomIn, cam }, { t: Math.max(e.t + T.zoomIn, e.until - T.zoomOut), cam }, { t: Math.max(e.t + T.zoomIn, e.until), cam: NO_CAM });
  }
  cams.sort((a, b) => a.t - b.t);

  // Pointer: straight legs with a slight arc between move targets; drags pin it to a window.
  const legs: Leg[] = [];
  const clicks: number[] = [];
  const drags: Timeline['drags'] = [];
  const keys: Timeline['keys'] = [];
  let at: Pt | undefined;
  let shownFrom: number | undefined;
  const pointer: Timeline['pointer'] = [];
  for (const e of events) {
    if (e.type === 'move') {
      const to = toCanvas(fit, e);
      const from = at ?? { x: to.x + 150, y: to.y + 120 };
      const dist = Math.hypot(to.x - from.x, to.y - from.y);
      const dur = e.dur ?? clamp(280 + dist * 0.5, 380, 760);
      legs.push({ from, to, start: e.t, end: e.t + dur });
      at = to;
      shownFrom ??= e.t;
    } else if (e.type === 'click') clicks.push(e.t);
    else if (e.type === 'drag') {
      drags.push(e);
      const w = data.windows.find((x) => x.id === e.window);
      if (w) {
        // The pointer stays where it let go (the window may still snap away from it).
        const b = boundsAt(w, e.until);
        at = toCanvas(fit, { x: b.x + e.dx, y: b.y + e.dy });
        legs.push({ from: at, to: at, start: e.until, end: e.until });
      }
    } else if (e.type === 'keys') keys.push(e);
    else if (e.type === 'pointer') {
      if (e.visible) shownFrom ??= e.t;
      else if (shownFrom !== undefined) { pointer.push({ from: shownFrom, to: e.t }); shownFrom = undefined; }
    }
  }
  if (shownFrom !== undefined) pointer.push({ from: shownFrom, to: loopAt });
  legs.sort((a, b) => a.start - b.start);

  return { data, fit, loopAt, total, windows, captions, cams, legs, clicks, drags, keys, pointer };
}

export function camAt(tl: Timeline, t: number): Cam {
  const ks = tl.cams;
  let a = ks[0]!;
  for (const k of ks) {
    if (k.t > t) {
      const p = ease(clamp((t - a.t) / Math.max(1, k.t - a.t)));
      const lerp = (x: number, y: number) => x + (y - x) * p;
      return { s: a.cam.s * (k.cam.s / a.cam.s) ** p, fx: lerp(a.cam.fx, k.cam.fx), fy: lerp(a.cam.fy, k.cam.fy), sx: lerp(a.cam.sx, k.cam.sx), sy: lerp(a.cam.sy, k.cam.sy) };
    }
    a = k;
  }
  return a.cam;
}

/** Pointer position (canvas), opacity and press state at `t`. */
export function pointerAt(tl: Timeline, t: number): { x: number; y: number; opacity: number; press: number; ripple?: number } | null {
  const span = tl.pointer.find((p) => t >= p.from && t < p.to + 250);
  if (!span) return null;
  let pos: Pt | undefined;
  for (const leg of tl.legs) {
    if (leg.start > t) break;
    if (t >= leg.end) { pos = leg.to; continue; }
    const p = glide(clamp((t - leg.start) / (leg.end - leg.start)));
    const dx = leg.to.x - leg.from.x;
    const dy = leg.to.y - leg.from.y;
    // A slight arc, like a hand moving a mouse.
    const len = Math.hypot(dx, dy) || 1;
    const arc = Math.sin(Math.PI * p) * len * 0.06;
    pos = { x: leg.from.x + dx * p - (dy / len) * arc, y: leg.from.y + dy * p + (dx / len) * arc };
  }
  let press = 0;
  for (const d of tl.drags) {
    if (t < d.t || t > d.until) continue;
    const w = tl.data.windows.find((x) => x.id === d.window);
    if (!w) continue;
    const b = boundsAt(w, t);
    pos = toCanvas(tl.fit, { x: b.x + d.dx, y: b.y + d.dy });
    press = 1;
  }
  if (!pos) return null;
  let ripple: number | undefined;
  for (const c of tl.clicks) {
    if (t < c - 60 || t >= c + 500) continue;
    const d = t - c;
    press = Math.max(press, d < 0 ? clamp((d + 60) / 60) : clamp(1 - (d - 60) / 120));
    if (d >= 0) ripple = d / 500;
  }
  const opacity = Math.min(clamp((t - span.from) / 180), clamp((span.to + 250 - t) / 250));
  return { ...pos, opacity, press, ripple };
}

/** Opacity of a window at `t`: fades in thirds when it opens or closes mid-scene (a GIF repaints blends). */
export function windowOpacity(tl: Timeline, w: WindowTrack, t: number): number {
  if (t < w.from || t > w.to + T.windowFade) return 0;
  const inP = w.from <= 0 ? 1 : clamp((t - w.from) / T.windowFade);
  const outP = w.to >= tl.loopAt ? 1 : clamp((w.to + T.windowFade - t) / T.windowFade);
  return Math.ceil(Math.min(inP, outP) * 3) / 3;
}
