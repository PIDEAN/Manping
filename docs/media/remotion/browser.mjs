// Used by render.mjs.
import { existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** Playwright's headless shell, when installed, saves Remotion a browser download. */
export function headlessShell() {
  for (const cache of [join(homedir(), 'Library/Caches/ms-playwright'), join(homedir(), '.cache/ms-playwright')]) {
    if (!existsSync(cache)) continue;
    const dirs = readdirSync(cache).filter((d) => d.startsWith('chromium_headless_shell-')).sort().reverse();
    for (const d of dirs) {
      for (const sub of readdirSync(join(cache, d))) {
        const bin = join(cache, d, sub, process.platform === 'win32' ? 'chrome-headless-shell.exe' : 'chrome-headless-shell');
        if (existsSync(bin)) return bin;
      }
    }
  }
  return undefined;
}

/** `--browser-executable=…` for the Remotion CLI, or nothing. */
export const browserArgs = () => {
  const bin = headlessShell();
  return bin ? [`--browser-executable=${bin}`] : [];
};
