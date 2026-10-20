#!/usr/bin/env python3
"""Downloads the README demo assets listed in docs/media/assets.json into docs/media/.assets/.

Images come from Wikimedia Commons at the width the app shows them (covers 1280 px, avatars 400 px);
the two demo videos are still photos (1920×1080) joined with ffmpeg, one per chapter. Files already
present are kept. Nothing here is committed.

    python3 docs/media/fetch_assets.py [--force]
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

MEDIA = Path(__file__).resolve().parent
OUT = MEDIA / ".assets"
UA = {"User-Agent": "ManpingReadmeMedia/1.0 (https://github.com/PIDEAN/Manping)"}
API = "https://commons.wikimedia.org/w/api.php"


def api(**params):
    url = API + "?" + urllib.parse.urlencode({"action": "query", "format": "json", **params})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 4:
                raise
            time.sleep(10 * (attempt + 1))


def replace_when_done(target, write):
    """Runs `write(partial)` on a temporary file beside `target` and moves it into place only when
    it succeeds, so an interrupted download or encode is never mistaken for a finished file."""
    partial = target.with_name(target.name + ".part")
    try:
        write(partial)
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)


def download(url, target):
    """Fetches `url` through the system proxy (ffmpeg would not use it)."""
    def write(partial):
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=300) as response, \
                open(partial, "wb") as file:
            while chunk := response.read(1 << 20):
                file.write(chunk)
    replace_when_done(target, write)


def image(entry, width, target, force):
    if target.exists() and not force:
        return
    pages = api(titles="File:" + entry["file"], prop="imageinfo", iiprop="url", iiurlwidth=width)["query"]["pages"]
    info = next(iter(pages.values()))["imageinfo"][0]
    download(info["thumburl"], target)
    print("  ", target.name if not target.is_relative_to(MEDIA) else target.relative_to(MEDIA), "←", entry["file"])
    time.sleep(0.5)


def video(entry, target, force):
    """A demo video made of still photos (one per chapter): the player, its chapters and the seek
    preview behave as with footage, while the picture stays still so the GIF only carries what the
    interface changes."""
    if target.exists() and not force:
        return
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        stills = entry["stills"]
        marks = [still["start"] for still in stills] + [entry["duration"]]
        command = ["ffmpeg", "-v", "error", "-y"]
        for index, still in enumerate(stills):
            photo = work / f"{index}.jpg"
            image(still, 1920, photo, True)
            command += ["-loop", "1", "-framerate", "30", "-t", str(marks[index + 1] - marks[index]), "-i", str(photo)]
        chapters = any(still.get("chapter") for still in stills)
        if chapters:
            meta = work / "chapters.txt"
            lines = [";FFMETADATA1"]
            for index, still in enumerate(stills):
                lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={marks[index] * 1000}",
                          f"END={marks[index + 1] * 1000}", f"title={still['chapter']}"]
            meta.write_text("\n".join(lines) + "\n")
            command += ["-i", str(meta)]
        frame = "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1"
        graph = ";".join(f"[{i}:v]{frame}[v{i}]" for i in range(len(stills)))
        graph += ";" + "".join(f"[v{i}]" for i in range(len(stills))) + f"concat=n={len(stills)}:v=1:a=0[out]"
        command += ["-filter_complex", graph, "-map", "[out]"]
        if chapters:
            command += ["-map_chapters", str(len(stills))]
        command += ["-r", "30", "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-tune", "stillimage",
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-f", "mp4"]
        replace_when_done(target, lambda partial: subprocess.run(command + [str(partial)], check=True))
    print("  ", target.relative_to(MEDIA), "←", ", ".join(still["file"] for still in stills))


def main():
    force = "--force" in sys.argv
    manifest = json.loads((MEDIA / "assets.json").read_text())
    for folder in ("covers", "avatars"):
        (OUT / folder).mkdir(parents=True, exist_ok=True)
    for index, entry in enumerate(manifest["covers"]):
        image(entry, 1280, OUT / "covers" / f"{index}.jpg", force)
    for index, entry in enumerate(manifest["avatars"]):
        image(entry, 400, OUT / "avatars" / f"{index}.jpg", force)
    for name, entry in manifest["videos"].items():
        video(entry, OUT / f"{name}.mp4", force)
    print(OUT)


if __name__ == "__main__":
    main()
