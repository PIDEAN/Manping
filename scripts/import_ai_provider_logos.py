#!/usr/bin/env python3
"""Import AI provider logos from LobeHub's MIT-licensed @lobehub/icons-static-svg.

Usage: npm pack @lobehub/icons-static-svg@1.95.1, extract it, then
  python3 scripts/import_ai_provider_logos.py <extracted>/package/icons

Files are written as Sources/ManpingApp/Resources/AIProviders/<provider rawValue>.svg, sized
24x24 and with packed arc flags expanded (CoreSVG rejects `a…0 01…` path data).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'Sources/ManpingApp/Resources/AIProviders'
# Brand colour variants where LobeHub ships one; mono marks use currentColor (themed at load).
MAPPING = {
    'openai': 'openai.svg', 'azure_openai': 'azure-color.svg', 'azure_ai': 'azureai-color.svg', 'xai': 'xai.svg',
    'zhipu': 'zhipu-color.svg', 'lingyi': 'yi-color.svg', 'anthropic': 'anthropic.svg', 'moonshot': 'moonshot.svg',
    'gemini': 'gemini-color.svg', 'deepseek': 'deepseek-color.svg', 'qwen': 'qwen-color.svg', 'ernie': 'wenxin-color.svg',
    'hunyuan': 'hunyuan-color.svg', 'spark': 'spark-color.svg', 'doubao': 'doubao-color.svg',
    'siliconflow': 'siliconcloud-color.svg', 'open_router': 'openrouter.svg', 'together_ai': 'together-color.svg',
    'groq': 'groq.svg', 'ollama': 'ollama.svg', 'mistral': 'mistral-color.svg', 'perplexity': 'perplexity-color.svg',
    'chatgpt_plan': 'openai.svg',
    'minimax': 'minimax-color.svg', 'minimax_plan': 'minimax-color.svg',
    'xiaomi_mimo': 'xiaomimimo.svg', 'mimo_token_plan': 'xiaomimimo.svg',
    'opencode_zen': 'opencode.svg', 'opencode_go': 'opencode.svg', 'lm_studio': 'lmstudio.svg',
}
NUMBER = re.compile(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')


def normalize_path(data):
    tokens, index, command, argument = [], 0, None, 0
    while index < len(data):
        char = data[index]
        if char.isalpha():
            command, argument = char, 0
            tokens.append(char); index += 1
            continue
        if char in ' ,\t\n\r':
            index += 1
            continue
        if command and command.lower() == 'a' and argument % 7 in (3, 4) and char in '01':
            tokens.append(char); index += 1; argument += 1  # one-digit large-arc / sweep flag
            continue
        match = NUMBER.match(data, index)
        if not match:
            raise ValueError(f'unexpected path data near {data[index:index + 20]!r}')
        tokens.append(match.group()); index = match.end(); argument += 1
    result = ''
    for token in tokens:
        result += token if token.isalpha() or not result or result[-1].isalpha() else ' ' + token
    return result


def convert(text):
    head, body = text.split('>', 1)
    head = re.sub(r'\s(height|width)="1em"', '', head)
    head = re.sub(r'\sstyle="[^"]*"', '', head)
    head = head.replace('<svg', '<svg width="24" height="24"', 1)
    body = re.sub(r'\sd="([^"]*)"', lambda match: ' d="' + normalize_path(match.group(1)) + '"', body)
    return head + '>' + body


def main():
    source = pathlib.Path(sys.argv[1])
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for provider, name in MAPPING.items():
        (DESTINATION / f'{provider}.svg').write_text(convert((source / name).read_text()))
    print(f'imported {len(MAPPING)} logos into {DESTINATION.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
