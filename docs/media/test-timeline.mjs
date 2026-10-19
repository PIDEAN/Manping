// Offline check of the composition and the GIF encoder, without the app or screen recording: builds
// .out/test.json over four still screenshots (main window: 首页 then 视频页, the 小窗 panel, the settings window)
// with a pointer, a click, a zoom, key presses, a drag and captions. Then:
//   pnpm --dir docs/media/remotion render test      → docs/media/.out/test.gif
//
// Usage: node docs/media/test-timeline.mjs [screenshot dir]
// The directory needs popular.png and video.png (main window, 2× and without shadow), settings-network.png
// (settings window) and video-mini.png (the mini panel, captured with its shadow) — e.g. the output of
// `scripts/live_check.py --fixture --mini`. When .out/demo-media.mp4 exists (docs/media/demo-media.sh), the
// mini window shows recorded-style frames from it instead of the still. Each file is looked up first under the path on the right of
// `fallback` below (fixture screenshots kept in .build/live-private), then by its own name, in that directory
// and then in this checkout's .build/live-private.
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '../..');
const OUT = join(HERE, '.out');
const source = process.argv[2];
const fallback = {
  'popular.png': 'real-dark/popular.png',
  'video.png': 'real-dark/video.png',
  'settings-network.png': 'readme/settings-network.png',
  'video-mini.png': 'mini-check3/video-mini.png',
};
mkdirSync(join(OUT, 'test'), { recursive: true });
for (const [name, alt] of Object.entries(fallback)) {
  // The named sub-folders hold offline-sample (fixture) screenshots; prefer them over same-named live ones.
  const from = [source && join(source, alt), source && join(source, name), join(ROOT, '.build/live-private', alt)].find((p) => p && existsSync(p));
  if (!from) throw new Error(`No ${name}: pass a directory with the screenshots`);
  copyFileSync(from, join(OUT, 'test', name));
}
// A recorded-style window too: 4.9 s of the demo video at 25 fps stands in for the mini window's frames, so
// the frame-sequence path (and the cost of moving pictures in the GIF) is checked as well.
const media = join(OUT, 'demo-media.mp4');
const recorded = existsSync(media);
if (recorded) {
  rmSync(join(OUT, 'test/mini'), { recursive: true, force: true });
  mkdirSync(join(OUT, 'test/mini'), { recursive: true });
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', '8', '-t', '4.9', '-i', media, '-vf', 'fps=25,scale=960:540', '-start_number', '0', join(OUT, 'test/mini/%05d.png')]);
}

// A 1512 × 982 pt screen: the main window (1362 × 895 pt) in the middle, the mini window in the corners.
const main = { x: 75, y: 45, w: 1362, h: 895 };
const miniStart = { x: 1512 - 16 - 480, y: 982 - 16 - 270, w: 480, h: 270 };
const miniEnd = { x: 16, y: 33 + 16, w: 480, h: 270 };
const settings = { x: 376, y: 190, w: 760, h: 560 };
const ease = (p) => (p < 0.5 ? 4 * p * p * p : 1 - (-2 * p + 2) ** 3 / 2);

// The drag: bounds samples every 40 ms between 7600 and 8600 ms, a drop short of the corner, then the snap.
const miniBounds = [{ t: 0, ...miniStart }];
for (let t = 7600; t <= 8600; t += 40) {
  const p = ease((t - 7600) / 1000);
  miniBounds.push({ t, w: 480, h: 270, x: miniStart.x + (miniEnd.x + 40 - miniStart.x) * p, y: miniStart.y + (miniEnd.y + 30 - miniStart.y) * p });
}
for (let t = 8640; t <= 8840; t += 40) {
  const p = ease((t - 8600) / 240);
  miniBounds.push({ t, w: 480, h: 270, x: miniEnd.x + 40 * (1 - p), y: miniEnd.y + 30 * (1 - p) });
}

const data = {
  scene: 'test',
  title: '合成测试',
  duration: 11000,
  windows: [
    { id: 'main', z: 0, from: 0, to: 11000, bounds: [{ t: 0, ...main }], stills: [{ t: 0, img: 'test/popular.png' }, { t: 1900, img: 'test/video.png' }] },
    recorded
      ? { id: 'mini', z: 1, from: 6100, to: 11000, bounds: miniBounds, segments: [{ start: 6100, count: 122, dir: 'test/mini', digits: 5 }] }
      // The mini screenshot carries the panel's own shadow: 23 pt each side, 19 pt above, 27 pt below.
      : { id: 'mini', z: 1, from: 6100, to: 11000, bounds: miniBounds, stills: [{ t: 0, img: 'test/video-mini.png' }], margin: { l: 23, t: 19, r: 23, b: 27 }, shadow: false },
    { id: 'settings', z: 2, from: 9500, to: 11000, bounds: [{ t: 0, ...settings }], stills: [{ t: 0, img: 'test/settings-network.png' }] },
  ],
  events: [
    { t: 0, type: 'caption', text: '原生 SwiftUI 界面，液态玻璃控件，Metal 弹幕跟随屏幕刷新率匀速滚动' },
    { t: 600, type: 'move', x: main.x + 386, y: main.y + 151 },
    { t: 1600, type: 'click' },
    { t: 2600, type: 'move', x: main.x + 605, y: main.y + 813 },
    { t: 3400, type: 'zoom', x: main.x + 230, y: main.y + 700, w: 760, h: 190, until: 5400 },
    { t: 5800, type: 'keys', keys: ['⇧', '⌘', 'P'] },
    { t: 5800, type: 'caption', text: '⇧⌘P 打开小窗，主窗口继续浏览，播放不中断' },
    { t: 6800, type: 'move', x: miniStart.x + 240, y: miniStart.y + 60 },
    { t: 7600, type: 'drag', window: 'mini', dx: 240, dy: 60, until: 8600 },
    { t: 9200, type: 'keys', keys: ['⌘', ','] },
    { t: 9200, type: 'caption', text: '设置窗口：网络节点、代理与致谢' },
    { t: 10200, type: 'pointer', visible: false },
  ],
};
writeFileSync(join(OUT, 'test.json'), JSON.stringify(data, null, 1));
console.log(join(OUT, 'test.json'));
