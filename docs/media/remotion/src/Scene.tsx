// One README animation: the recorded windows on a soft desktop, with the pointer, clicks, camera moves, key
// presses and a one-line caption in a glass capsule laid over them.
import { useMemo } from 'react';
import { AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import icon from '../../../../Resources/AppIcon/AppIcon.png';
import {
  boundsAt, boxToCanvas, build, camAt, CAPTION_Y, clamp, ease, frameAt, H, pointerAt, T, W, windowOpacity,
  type SceneData, type Timeline, type WindowTrack,
} from './timeline';

export type SceneProps = { scene: string; title: string; data: SceneData | null };

const FONT = '-apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif';
/** Design tokens (docs/DesignSystem.md): ink-blue backdrop, the accent, danmaku pink and amber. */
const INK = '#0b0e16';
const ACCENT = '46,192,247';
const PINK = '255,79,149';
const AMBER = '255,177,59';

/** A quiet desktop: the icon's ink-blue gradient with two soft glows. Static, so it costs the GIF nothing. */
function Desktop() {
  return (
    <AbsoluteFill
      style={{
        background: [
          `radial-gradient(900px 620px at 12% 8%, rgba(${ACCENT},.20), rgba(${ACCENT},0) 70%)`,
          `radial-gradient(820px 600px at 92% 96%, rgba(${PINK},.14), rgba(${PINK},0) 70%)`,
          `radial-gradient(700px 500px at 70% 10%, rgba(${AMBER},.07), rgba(${AMBER},0) 70%)`,
          'linear-gradient(180deg, #262e47 0%, #121725 58%, #0b0e16 100%)',
        ].join(','),
      }}
    />
  );
}

function Window({ tl, w, t }: { tl: Timeline; w: WindowTrack; t: number }) {
  const o = windowOpacity(tl, w, t);
  const src = frameAt(w, Math.min(t, w.to));
  if (o <= 0 || !src) return null;
  const b = boxToCanvas(tl.fit, boundsAt(w, t));
  const m = w.margin ?? { l: 0, t: 0, r: 0, b: 0 };
  const s = tl.fit.s;
  return (
    <Img
      src={staticFile(src)}
      style={{
        position: 'absolute',
        left: b.x - m.l * s,
        top: b.y - m.t * s,
        width: b.w + (m.l + m.r) * s,
        height: b.h + (m.t + m.b) * s,
        opacity: o,
        // The recorded frames keep the window's own rounded corners (alpha), so the shadow follows them.
        filter: w.shadow === false ? undefined : 'drop-shadow(0 0 0.5px rgba(255,255,255,.18)) drop-shadow(0 22px 40px rgba(0,0,0,.5))',
      }}
    />
  );
}

/** The macOS arrow: black with a white rim, tip at (x, y). */
function Pointer({ tl, t }: { tl: Timeline; t: number }) {
  const p = pointerAt(tl, t);
  if (!p) return null;
  return (
    <>
      {p.ripple !== undefined && p.ripple < 1 && (
        <div
          style={{
            position: 'absolute',
            left: p.x - 24,
            top: p.y - 24,
            width: 48,
            height: 48,
            borderRadius: 24,
            border: `2px solid rgba(${ACCENT},.85)`,
            background: `rgba(${ACCENT},.16)`,
            opacity: (1 - p.ripple) * p.opacity,
            transform: `scale(${0.3 + 0.9 * ease(p.ripple)})`,
          }}
        />
      )}
      <svg
        width={28}
        height={28}
        viewBox="0 0 28 28"
        style={{ position: 'absolute', left: p.x - 7, top: p.y - 4, opacity: p.opacity, transform: `scale(${1 - 0.14 * p.press})`, transformOrigin: '7px 4px', filter: 'drop-shadow(0 1.5px 2px rgba(0,0,0,.4))', overflow: 'visible' }}
      >
        <path d="M7 4v17.6l4.4-4.3 3 6.9 3.1-1.3-3-6.8h6.3z" fill="#000" stroke="#fff" strokeWidth={1.5} strokeLinejoin="round" />
      </svg>
    </>
  );
}

/** Key presses (⇧⌘P, ⌘,) as keycaps in a glass capsule over the bottom of the stage. */
function Keys({ tl, t }: { tl: Timeline; t: number }) {
  const k = tl.keys.find((x) => t >= x.t && t < x.t + T.keys);
  if (!k) return null;
  const inP = clamp((t - k.t) / 140);
  const outP = clamp((k.t + T.keys - t) / 200);
  return (
    <div style={{ position: 'absolute', left: 0, width: W, top: CAPTION_Y - 118, display: 'flex', justifyContent: 'center', opacity: Math.min(inP, outP) }}>
      <div
        style={{
          display: 'flex',
          gap: 8,
          padding: 8,
          borderRadius: 18,
          background: 'rgba(20,24,36,.72)',
          backdropFilter: 'blur(18px) saturate(1.4)',
          boxShadow: '0 0 0 1px rgba(255,255,255,.12), 0 14px 34px rgba(0,0,0,.4)',
          transform: `translateY(${(1 - inP) * 8}px) scale(${0.92 + 0.08 * inP})`,
        }}
      >
        {k.keys.map((key, j) => {
          const d = clamp((t - k.t - j * 110) / 120);
          return (
            <span
              key={j}
              style={{
                minWidth: 48,
                height: 48,
                padding: '0 12px',
                boxSizing: 'border-box',
                borderRadius: 11,
                background: `linear-gradient(180deg, rgba(255,255,255,${0.16 + 0.1 * d}), rgba(255,255,255,.08))`,
                boxShadow: 'inset 0 0 0 1px rgba(255,255,255,.16), 0 2px 0 rgba(0,0,0,.35)',
                color: '#eef1f6',
                fontSize: 24,
                fontWeight: 600,
                display: 'grid',
                placeItems: 'center',
                transform: `translateY(${d * 2}px)`,
              }}
            >
              {key}
            </span>
          );
        })}
      </div>
    </div>
  );
}

/** The caption capsule: brand on the left, the current line on the right; lines change with a short slide. */
function Caption({ tl, t, back }: { tl: Timeline; t: number; back: number }) {
  let k = 0;
  tl.captions.forEach((c, i) => { if (c.at <= t) k = i; });
  const cur = tl.captions[k];
  const prev = tl.captions[k - 1];
  const first = tl.captions[0];
  const p = k === 0 ? 1 : clamp((t - (cur?.at ?? 0)) / (T.caption * 1.5));
  const line = (text: string, o: number, dy: number) => (
    <span style={{ position: 'absolute', left: 0, top: 0, whiteSpace: 'nowrap', opacity: o, transform: `translateY(${dy}px)` }}>{text}</span>
  );
  // The capsule fits the longest line, so it never resizes mid-animation.
  const longest = tl.captions.reduce((a, c) => (c.text.length > a.length ? c.text : a), '');
  return (
    <div style={{ position: 'absolute', left: 0, width: W, top: CAPTION_Y - 24, display: 'flex', justifyContent: 'center' }}>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          height: 48,
          padding: '0 22px 0 10px',
          borderRadius: 24,
          background: 'rgba(22,27,40,.62)',
          backdropFilter: 'blur(20px) saturate(1.5)',
          boxShadow: 'inset 0 0 0 1px rgba(255,255,255,.14), inset 0 1px 0 rgba(255,255,255,.12), 0 12px 32px rgba(0,0,0,.35)',
          color: '#eef1f6',
          maxWidth: W - 80,
        }}
      >
        <Img src={icon} style={{ width: 30, height: 30 }} />
        <span style={{ fontSize: 16, fontWeight: 700, letterSpacing: 2, color: '#eef1f6' }}>满屏</span>
        {tl.data.title && <span style={{ fontSize: 13, fontWeight: 600, color: `rgb(${ACCENT})`, background: `rgba(${ACCENT},.14)`, padding: '3px 9px', borderRadius: 9 }}>{tl.data.title}</span>}
        <span style={{ width: 1, height: 18, background: 'rgba(255,255,255,.18)' }} />
        <div style={{ position: 'relative', height: 26, fontSize: 18, letterSpacing: 0.3, lineHeight: '26px' }}>
          <span style={{ visibility: 'hidden', whiteSpace: 'nowrap' }}>{longest}</span>
          {back > 0 && first && cur && first.text !== cur.text ? (
            <>
              {line(cur.text, 1 - clamp(back * 2.2), -6 * back)}
              {line(first.text, clamp((back - 0.35) / 0.65), 6 * (1 - back))}
            </>
          ) : (
            <>
              {prev && p < 1 && line(prev.text, 1 - clamp(p * 2.2), -6 * p)}
              {cur && line(cur.text, clamp((p - 0.35) / 0.65), 6 * (1 - p))}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

export function Scene({ data }: SceneProps) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const tl = useMemo(() => (data ? build(data) : null), [data]);
  if (!tl) return <AbsoluteFill style={{ background: INK }} />;
  const t = (frame / fps) * 1000;
  if (t >= tl.loopAt) {
    // Loop: the opening frame fades in over the last one in four steps (each step repaints the whole GIF frame).
    const q = Math.ceil(clamp((t - tl.loopAt) / (tl.total - tl.loopAt)) * 4) / 4;
    return (
      <AbsoluteFill style={{ fontFamily: FONT }}>
        <Desktop />
        <Stage tl={tl} t={tl.loopAt - 1} />
        <AbsoluteFill style={{ opacity: q }}>
          <Desktop />
          <Stage tl={tl} t={0} />
        </AbsoluteFill>
        <Caption tl={tl} t={tl.loopAt - 1} back={q} />
      </AbsoluteFill>
    );
  }
  return (
    <AbsoluteFill style={{ fontFamily: FONT }}>
      <Desktop />
      <Stage tl={tl} t={t} />
      <Keys tl={tl} t={t} />
      <Caption tl={tl} t={t} back={0} />
    </AbsoluteFill>
  );
}

function Stage({ tl, t }: { tl: Timeline; t: number }) {
  // Camera moves step every 80 ms: whole-frame changes are what make a GIF heavy; the pointer stays smooth.
  const cam = camAt(tl, Math.floor(t / 80) * 80);
  return (
    <AbsoluteFill style={{ width: W, height: H, transformOrigin: '0 0', transform: `translate(${cam.sx - cam.s * cam.fx}px, ${cam.sy - cam.s * cam.fy}px) scale(${cam.s})` }}>
      {tl.windows.map((w) => <Window key={w.id} tl={tl} w={w} t={t} />)}
      <Pointer tl={tl} t={t} />
    </AbsoluteFill>
  );
}
