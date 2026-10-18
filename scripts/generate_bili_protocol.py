#!/usr/bin/env python3
"""Regenerate the locked BiliKernel protocol messages and independent fake wire fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, **kwargs):
    return subprocess.check_output(args, cwd=ROOT, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="compare without changing generated sources")
    parser.add_argument("--protoc", default=shutil.which("protoc"))
    options = parser.parse_args()
    lock = json.loads((ROOT / "Protocols/codegen.lock.json").read_text())
    manifest = json.loads((ROOT / "Protocols/BiliKernel/manifest.json").read_text())
    for name, digest in manifest["files"].items():
        assert sha(ROOT / "Protocols/BiliKernel" / name) == digest, f"Changed locked proto: {name}"
    assert sha(ROOT / "Protocols/GoogleProtobuf/google/protobuf/any.proto") == lock["googleAny"]
    protoc = Path(options.protoc).resolve()
    assert run([str(protoc), "--version"], text=True).strip() == lock["protoc"]["version"]
    assert sha(protoc) == lock["protoc"]["sha256"], "protoc binary differs from the recorded lock"
    checkout = ROOT / ".build/checkouts/swift-protobuf"
    assert run(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip() == lock["generators"]["protoc-gen-swift"]["revision"]
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    scratch = ROOT / ".build/codegen-swift"
    run(["swift", "build", "--package-path", str(checkout), "--scratch-path", str(scratch),
         "--product", "protoc-gen-swift", "--arch", "arm64"], env=env)
    generator = scratch / "debug/protoc-gen-swift"
    generated_dir = ROOT / "Sources/BiliProtocol"
    with tempfile.TemporaryDirectory(prefix="bili-protocol-") as temp:
        output = Path(temp)
        run([str(protoc), "-I", "Protocols/BiliKernel", "-I", "Protocols/GoogleProtobuf",
             f"--plugin=protoc-gen-swift={generator}", f"--swift_out={output}",
             "--swift_opt=Visibility=Public,FileNaming=PathToUnderscores",
             *sorted(manifest["files"])])
        actual = {p.name: sha(p) for p in output.glob("*.swift")}
        if options.check:
            expected = json.loads((ROOT / "Protocols/generated.lock.json").read_text())["files"]
            assert actual == expected, "Generated output differs from lock"
            assert {p.name: sha(p) for p in generated_dir.glob("*.swift")} == actual, "Checked-in generated source differs"
        else:
            generated_dir.mkdir(exist_ok=True)
            for old in generated_dir.glob("*.pb.swift"):
                old.unlink()
            for source in output.glob("*.swift"):
                shutil.copyfile(source, generated_dir / source.name)
            (ROOT / "Protocols/generated.lock.json").write_text(json.dumps({
                "schemaRevision": manifest["revision"], "generator": lock["generators"]["protoc-gen-swift"],
                "files": dict(sorted(actual.items()))}, indent=2) + "\n")
    fixtures = ROOT / "Tests/ManpingCoreTests/Fixtures/RPC"
    fixture_manifest = json.loads((fixtures / "manifest.json").read_text())
    for name, record in fixture_manifest["messages"].items():
        wire = run([str(protoc), "-I", "Protocols/BiliKernel", "-I", "Protocols/GoogleProtobuf",
                    f'--encode={record["type"]}', record["proto"]], input=(fixtures / f"{name}.textproto").read_bytes())
        assert hashlib.sha256(wire).hexdigest() == record["sha256"], f"Fixture changed: {name}"
        if options.check:
            assert wire == (fixtures / f"{name}.bin").read_bytes(), f"Fixture bytes differ: {name}"
        else:
            (fixtures / f"{name}.bin").write_bytes(wire)
    print(f'Verified {len(actual)} generated Swift files and {len(fixture_manifest["messages"])} fake wire fixtures')


if __name__ == "__main__":
    main()
