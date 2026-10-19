"""Remove machine-specific paths and credentials from developer measurement text."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BUILD = (ROOT / '.build').resolve()


def portable(path):
    path = Path(path).resolve()
    if path.is_relative_to(BUILD):
        return '.build/' + str(path.relative_to(BUILD))
    if path.is_relative_to(ROOT):
        return str(path.relative_to(ROOT))
    return path.name


def scrub(text):
    for path, replacement in sorted([(str(BUILD), '.build'), (str(ROOT), '<PROJECT>'),
                                     (str(Path.home()), '<HOME>')], key=lambda item: -len(item[0])):
        text = text.replace(path, replacement)
    text = re.sub(r'/Users/[^/\s]+', '<HOME>', text)
    text = re.sub(r'/(?:private/)?var/folders/[^\s\"\']+', '<TEMP>', text)
    text = re.sub(r'/(?:Applications|System|usr|opt|Library|private|var|tmp|Volumes|dev|Users)(?:/[^\s\"\'<>;,)}\]]+)*', '<PATH>', text)
    text = re.sub(r'(?i)\b(?:Cookie|Authorization|Set-Cookie):[^\n]*', '<REDACTED_HEADER>', text)
    text = re.sub(r'(?i)(SESSDATA|bili_jct|access_token|refresh_token)=([^&;\s]+)', r'\1=<REDACTED>', text)
    # The relay's randomly generated URL capability is not needed in measurement artifacts.
    return re.sub(r'(/r/)[a-f0-9]{16,}(/)', r'\1<REDACTED>\2', text)


def scrub_file(path):
    path = Path(path)
    if path.is_file():
        text = path.read_text(errors='replace')
        clean = scrub(text)
        if clean != text:
            path.write_text(clean)
