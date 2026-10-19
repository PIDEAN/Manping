#!/usr/bin/env python3
"""Capture read-only pages from one existing Debug build, without rebuilding or signing."""
import argparse
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
WINDOW_PROBE = r'''
import CoreGraphics
import Foundation
let number = UInt32(CommandLine.arguments[1])!
let pid = Int(CommandLine.arguments[2])!
let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]] ?? []
guard list.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int) == pid }) else { exit(1) }
print("owned")
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/ui/满屏 Debug.app")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--pages", default="recommended,popular,ranking,partitions,search:动画,space,following,followers,favorites,later,history,moment,anime,anime:index,cinema,cinema:tv,cinema:documentary,live,article,article:ranking,messages:reply,messages:at,messages:like,messages:chat,settings,settings:playback,settings:danmaku,settings:network,settings:ai,downloads")
    parser.add_argument("--pgc", help="Optional public ss/ep identifier for native PGC playback")
    parser.add_argument("--video", help="Optional public AV/BV identifier for the playback page")
    parser.add_argument("--wait", type=float, default=30, help="Seconds per page; allow the build in a firewall on first launch")
    parser.add_argument("--fixture", action="store_true", help="Offline check using isolated synthetic samples")
    parser.add_argument("--theme", choices=["dark", "light"], default="dark")
    parser.add_argument("--video-tab", choices=["info", "parts", "episodes", "seasons", "collections", "related", "comments", "ai"])
    parser.add_argument("--ai-preview", action="store_true", help="Synthetic AI answer preview; fixture only")
    parser.add_argument("--ai-provider", help="Expand one provider's configuration card; fixture only")
    parser.add_argument("--ai-scene", choices=["intro", "chapters", "context", "highlights", "comments", "clips", "official", "settings"],
        help="AI panel scene with the offline fixture service (use with --video-tab ai; settings: 设置 › AI lower groups first); fixture only")
    parser.add_argument("--mini", action="store_true",
        help="Fixture only: open the mini window (小窗) on video pages, controls pinned, and capture it as <page>-mini.png")
    parser.add_argument("--app-args", default="",
        help="Extra launch arguments for the app, e.g. \"--ui-bar-drag insert --ui-player-bar quality,speed\"")
    parser.add_argument("--window-size", nargs=2, type=int, metavar=("WIDTH", "HEIGHT"), default=(1362, 895),
        help="Main window content size in points (720–3840 × 600–2160), e.g. 900 700 to check the narrow player panel")
    args = parser.parse_args()
    if (args.ai_preview or args.ai_provider or args.ai_scene) and not args.fixture:
        parser.error("--ai-preview requires --fixture; live checks never generate paid AI responses")
    if args.mini and not args.fixture:
        parser.error("--mini requires --fixture")
    if not (720 <= args.window_size[0] <= 3840 and 600 <= args.window_size[1] <= 2160):
        parser.error("--window-size must be within 720–3840 × 600–2160")
    if not 1 <= args.wait <= 120:
        parser.error("--wait must be between 1 and 120")
    if args.video and not re.fullmatch(r"(?:BV[0-9A-Za-z]{10}|av[1-9][0-9]*)", args.video):
        parser.error("--video must be a public AV/BV identifier")
    if args.pgc and not re.fullmatch(r"(?:ss|ep)[1-9][0-9]*", args.pgc):
        parser.error("--pgc must be a public ss/ep identifier")
    app = args.app.resolve()
    binary = app / "Contents/MacOS/Manping"
    if not binary.is_file():
        parser.error("Build the Debug app once before running this script")
    output = (args.output or (ROOT / "docs/screenshots/fixture" if args.fixture else ROOT / ".build/live-private")).resolve()
    if not args.fixture and not output.is_relative_to((ROOT / ".build/live-private").resolve()):
        parser.error("Live screenshots contain account information; save only under .build/live-private")
    output.mkdir(parents=True, exist_ok=True)
    pages = [page for page in args.pages.split(",") if page]
    if args.video:
        pages.append("video:" + args.video)
    print("使用同一构建；本脚本不构建、不签名、不执行账号写操作。", flush=True)
    if not args.fixture:
        print("首次请求时请在防火墙软件中放行此构建；请预先完成登录，截图期间不打开登录面板。", flush=True)
    if args.pgc:
        pages.append("pgc:" + args.pgc)
    failures = []
    with tempfile.TemporaryDirectory(prefix="manping-live-check-") as temporary:
        probe = Path(temporary) / "window.swift"
        probe.write_text(WINDOW_PROBE)
        env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
        for index, page in enumerate(pages, 1):
            label = page.replace(":", "-") if page.startswith(("anime:", "cinema:", "moment:", "article:", "messages:", "settings:", "downloads:")) else page.split(":", 1)[0]
            destination = output / (re.sub(r"[^a-zA-Z0-9_-]", "-", label) + ".png")
            window_file = app.parent / "window-id"
            window_file.unlink(missing_ok=True)
            mini_file = app.parent / "mini-window-id"
            mini_file.unlink(missing_ok=True)
            mini = args.mini and page.startswith("video:")
            argv = [str(binary), "--ui-page", page, "--ui-theme", args.theme,
                "--ui-window-size", str(args.window_size[0]), str(args.window_size[1])]
            if args.fixture:
                argv += ["--ui-fixture", "--skip-auth"]
            if args.video_tab and page.startswith(("video:", "pgc:")):
                argv += ["--ui-video-tab", args.video_tab]
            if args.ai_preview:
                argv += ["--ui-ai-preview"]
            argv += args.app_args.split()
            if args.ai_provider:
                argv += ["--ui-ai-provider", args.ai_provider]
            if args.ai_scene:
                argv += ["--ui-ai-scene", args.ai_scene]
            app_env = dict(os.environ, MANPING_UI_MINI_PLAYER="hover") if mini else None
            # Fallback when screen recording is unavailable: the app renders its own window
            # (no window shadow, and Liquid Glass may render flatter than on screen).
            snapshot = Path(temporary) / f"snapshot-{index}.png"
            argv += ["--ui-snapshot", str(snapshot), str(max(1, args.wait - 1))]
            process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=app_env)
            state_file = app.parent / f"capture-{process.pid}.state"
            try:
                deadline = time.monotonic() + 10
                while not window_file.exists():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("window unavailable")
                    time.sleep(.1)
                # A build launched from a script may stay in the background (Stage Manager then
                # shows only a thumbnail of its window); bring it to the front before capturing.
                subprocess.run(["osascript", "-e", "tell application \"System Events\" to set frontmost of "
                    f"(first process whose unix id is {process.pid}) to true"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                time.sleep(args.wait)
                if process.poll() is not None:
                    raise RuntimeError("app exited")
                if not state_file.exists() or state_file.read_text().strip() != "ready":
                    raise RuntimeError("authentication panel active; screenshot skipped")
                number = window_file.read_text().strip()
                subprocess.run(["swift", str(probe), number, str(process.pid)], env=env,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                captured = subprocess.run(["screencapture", "-x", "-o", "-l", number, str(destination)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                if not captured:
                    if not snapshot.exists():
                        raise RuntimeError("screen capture unavailable and no in-app snapshot")
                    destination.write_bytes(snapshot.read_bytes())
                    label += " (in-app snapshot)"
                width, height = struct.unpack(">II", destination.read_bytes()[16:24])
                if width < 700 or height < 500:
                    destination.unlink(missing_ok=True)
                    raise RuntimeError("window thumbnail captured; screenshot skipped")
                print(f"[{index}/{len(pages)}] {label}: {destination}", flush=True)
                if mini:
                    # The mini window is a separate panel; the main window above shows its placeholder.
                    if not mini_file.exists():
                        raise RuntimeError("mini window unavailable")
                    mini_number = mini_file.read_text().strip()
                    mini_destination = output / (re.sub(r"[^a-zA-Z0-9_-]", "-", label) + "-mini.png")
                    subprocess.run(["swift", str(probe), mini_number, str(process.pid)], env=env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                    subprocess.run(["screencapture", "-x", "-l", mini_number, str(mini_destination)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                    width, height = struct.unpack(">II", mini_destination.read_bytes()[16:24])
                    if width < 300 or height < 160:
                        mini_destination.unlink(missing_ok=True)
                        raise RuntimeError("mini window thumbnail captured; screenshot skipped")
                    print(f"[{index}/{len(pages)}] {label} 小窗: {mini_destination}", flush=True)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                failures.append(label)
                print(f"[{index}/{len(pages)}] {label}: SKIP ({error})", flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
                state_file.unlink(missing_ok=True)
    print("截图已生成；请逐页确认实网内容、空状态与错误状态。", flush=True)
    return 1 if failures else 0

if __name__ == "__main__":
    raise SystemExit(main())
