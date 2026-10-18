# Bili CDN Switcher

`Sources/ManpingCore/CDNCore.swift` ports the candidate, benchmark and stall-recovery policy of
Bili CDN Switcher (https://github.com/liiliiliil/bili-cdn-switcher): `*.bilivideo.com` host
validation, host-only URL swapping, the built-in UPOS seed list, the two-stage benchmark
(128 KB quick / 1 MB sustained, three finalists), the 15% automatic-switch threshold, the
buffer-trend recovery rule and the 15 s / 7 s recovery cooldowns. The relay, smart cache and
quality step-down are this project's own. No code was copied verbatim; the logic was rewritten
in Swift.

MIT License

Copyright (c) 2026 Bili CDN Switcher contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
