#!/usr/bin/env python3
"""許可済みのマイクを数値だけで計測、または専用NSTextViewで局所置換を比較する。"""
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", choices=("tap", "range"))
parser.add_argument("output", type=Path)
args = parser.parse_args()
output = args.output.resolve()
output.relative_to(ROOT / "build")
output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(["swift", "build", "--package-path", str(ROOT / "Packages/ForblazeKit")], check=True)
folder = Path(subprocess.check_output(["swift", "build", "--package-path", str(ROOT / "Packages/ForblazeKit"),
                                     "--show-bin-path"], text=True).strip())
objects = [path for module in ("ForblazeCore", "ForblazeApplication", "ForblazeMacOS")
           for path in sorted((folder / f"{module}.build").glob("*.o"))]
binary = output.parent / "device-check"
subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macosx26.0",
                "-I", str(folder / "Modules"), str(ROOT / "tools/improvement-check/device.swift"),
                *map(str, objects), "-o", str(binary)], check=True)
subprocess.run([str(binary), "--" + args.mode, str(output)], check=True)
