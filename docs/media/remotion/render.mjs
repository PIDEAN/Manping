// Renders the README animations: every composition to a PNG sequence, then to docs/images/<id>.gif with one
// palette per animation. Run after the recordings (`scripts/readme_media.sh` does both).
// `node render.mjs hero mini` renders only those scenes; `node render.mjs test` renders the offline check
// (docs/media/.out/test.json over still screenshots) to docs/media/.out/test.gif.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { browserArgs } from './browser.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const IMAGES = join(HERE, '../../images');
const OUT = join(HERE, '../.out');
const SCENES = ['hero', 'danmaku', 'mini', 'live', 'settings'];
const GIF_WIDTH = 1280;
/** Dense scenes (scrolling danmaku) fall back to narrower GIFs; 880 is the width the README shows. */
const WIDTHS = [GIF_WIDTH, 1080, 960, 880];
/** Budget per animation; above it the GIF is re-encoded at a lower frame rate (holds stay as they are). */
const LIMIT = 2.5 * 1024 * 1024;
const RATES = [25, 20, 15, 12.5];

const only = process.argv.slice(2);
let total = 0;
for (const id of only.length ? only : SCENES) {
  if (!SCENES.includes(id) && id !== 'test') throw new Error(`Unknown scene ${id}`);
  if (!existsSync(join(OUT, `${id}.json`))) throw new Error(`Missing ${join(OUT, `${id}.json`)}: record the scene first`);
  // Remotion refuses sequence folders with a dot anywhere in the path, so frames stay out of ../.out.
  const frames = join(HERE, 'frames', id);
  rmSync(frames, { recursive: true, force: true });
  execFileSync('pnpm', ['exec', 'remotion', 'render', 'src/index.ts', id, `frames/${id}`, '--sequence', '--image-format=png', ...browserArgs()], { cwd: HERE, stdio: ['ignore', 'ignore', 'inherit'] });
  const digits = /(\d+)\.png$/.exec(readdirSync(frames).sort()[0] ?? '')?.[1]?.length ?? 3;
  const dir = id === 'test' ? OUT : IMAGES;
  mkdirSync(dir, { recursive: true });
  const gif = join(dir, `${id}.gif`);
  let rate = RATES[0];
  let width = WIDTHS[0];
  const attempts = [...RATES.map((r) => [r, WIDTHS[0]]), ...WIDTHS.slice(1).map((w) => [RATES.at(-1), w])];
  for ([rate, width] of attempts) {
    // Repeated frames (holds) collapse into longer delays; flat UI colours need no dithering.
    const step = rate < 25 ? `fps=${rate},` : '';
    execFileSync('ffmpeg', [
      '-v', 'error', '-y', '-framerate', '25', '-i', join(frames, `element-%0${digits}d.png`),
      '-vf', `${step}mpdecimate=hi=64:lo=32:frac=0,scale=${width}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle`,
      '-fps_mode', 'vfr', '-loop', '0', gif,
    ], { stdio: 'inherit' });
    if (statSync(gif).size <= LIMIT) break;
  }
  const size = statSync(gif).size;
  total += size;
  const note = size > LIMIT ? `  over ${LIMIT / 1024 / 1024} MB even at ${rate} fps, ${width} px: shorten holds or the scene` : rate < 25 || width < GIF_WIDTH ? `  (${rate} fps, ${width} px to stay under ${LIMIT / 1024 / 1024} MB)` : '';
  console.log(`${id}.gif  ${(size / 1024).toFixed(0)} KB${note}`);
}
console.log(`total  ${(total / 1024 / 1024).toFixed(2)} MB`);
