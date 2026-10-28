#!/usr/bin/env python3
"""Test production Swift algorithms on Linux/macOS, optionally benchmark a Git baseline.

Builds an isolated, dependency-free SwiftPM package under .build; production files
are copied unchanged. This does not build the macOS app or simulate its renderer.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ("M8AIStreamParser.swift", "AITranscript.swift", "DownloadSubtitleCue.swift", "AITimecode.swift")
TESTS = ("PortableAIStreamTests.swift", "PortableTranscriptTests.swift")
MANIFEST = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "ManpingPortableCore",
  products: [.executable(name: "CoreBenchmark", targets: ["CoreBenchmark"])],
  targets: [
    .target(name: "ManpingCore", swiftSettings: [.define("MANPING_PORTABLE_CORE")]),
    .testTarget(name: "ManpingCoreTests", dependencies: ["ManpingCore"]),
    .executableTarget(name: "CoreBenchmark", dependencies: ["ManpingCore"]),
  ],
  swiftLanguageModes: [.v6]
)
'''


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, **kwargs)


def git(*args):
    # A container may run as a different UID from the mounted checkout's owner.
    return run("git", "-c", f"safe.directory={ROOT}", *args, capture_output=True).stdout


def prepare(label, ref=None):
    package = ROOT / ".build" / "portable-core" / label
    for directory in ("Sources/ManpingCore", "Sources/CoreBenchmark", "Tests/ManpingCoreTests"):
        (package / directory).mkdir(parents=True, exist_ok=True)
    (package / "Package.swift").write_text(MANIFEST)
    for name in SOURCES:
        path = f"Sources/ManpingCore/{name}"
        content = git("show", f"{ref}:{path}") if ref else (ROOT / path).read_text()
        (package / path).write_text(content)
    for name in TESTS:
        shutil.copyfile(ROOT / "Tests/ManpingCoreTests" / name, package / "Tests/ManpingCoreTests" / name)
    shutil.copyfile(ROOT / "scripts/fixtures/portable-core/Benchmark.swift", package / "Sources/CoreBenchmark/main.swift")
    return package


def benchmark(package, repeats):
    output = run(str(package / ".build/release/CoreBenchmark"), str(repeats), capture_output=True).stdout
    return json.loads(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--baseline-ref", help="Commit containing the portable source layout; only benchmarks it, not new regressions")
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/portable-core/results.json")
    args = parser.parse_args()
    if args.repeats < 3:
        parser.error("--repeats must be at least 3")
    if args.baseline_ref and not args.benchmark:
        parser.error("--baseline-ref requires --benchmark")
    current = prepare("current")
    run("swift", "test", "--package-path", str(current), "-c", "release", "-j", "2")
    if not args.benchmark:
        return
    # Finish both builds before timing; the benchmark processes run sequentially.
    baseline = prepare("baseline", args.baseline_ref) if args.baseline_ref else None
    for package in (current, baseline):
        if package:
            run("swift", "build", "--package-path", str(package), "-c", "release", "--product", "CoreBenchmark", "-j", "2")
    results = {
        "swift": run("swift", "--version", capture_output=True).stdout.strip(),
        "head": git("rev-parse", "HEAD").strip(),
        "dirty": bool(git("status", "--porcelain")),
        "baseline_ref": args.baseline_ref,
        "repeats": args.repeats,
    }
    if baseline:
        results["baseline"] = benchmark(baseline, args.repeats)
    results["current"] = benchmark(current, args.repeats)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
