#!/usr/bin/env python3
"""合成音声だけを使う比較。本文を含む結果は指定した新規buildディレクトリに保存する。"""
from pathlib import Path
import argparse
import json
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--prepare-model", action="store_true", help="比較前に通常のアプリと同じ日本語モデルを準備する")
    args = parser.parse_args()
    output = args.output.resolve()
    output.relative_to(ROOT / "build")
    output.mkdir(parents=True, exist_ok=False)
    corpus = [
        ("ordinary", "今日は会議の内容を確認して、明日の作業を決めます。", []),
        ("vocabulary", "フォルブレイズとクロードコードで、音声入力を確認します。", ["forblaze", "Claude Code"]),
    ]
    jobs = []
    for name, text, hints in corpus:
        audio = output / f"{name}.aiff"
        subprocess.run(["say", "-v", "Kyoko", "-r", "210", "-o", str(audio), text], check=True)
        jobs.append({"id": name, "path": str(audio), "expected": text, "hints": hints})
    jobs_path = output / "jobs.json"
    jobs_path.write_text(json.dumps(jobs, ensure_ascii=False, indent=2))
    subprocess.run(["swift", "build", "--package-path", str(ROOT / "Packages/ForblazeKit")], check=True)
    folder = Path(subprocess.check_output(["swift", "build", "--package-path", str(ROOT / "Packages/ForblazeKit"),
                                         "--show-bin-path"], text=True).strip())
    objects = [path for module in ("ForblazeCore", "ForblazeApplication", "ForblazeMacOS")
               for path in sorted((folder / f"{module}.build").glob("*.o"))]
    binary = output / "comparison"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macosx26.0",
                    "-I", str(folder / "Modules"), str(ROOT / "tools/improvement-check/main.swift"),
                    *map(str, objects), "-o", str(binary)], check=True)
    if args.prepare_model:
        subprocess.run([str(binary), "--prepare-model"], check=True)
    subprocess.run(["sandbox-exec", "-p", "(version 1) (allow default) (deny network*)",
                    str(binary), str(jobs_path), str(output / "measurements.jsonl")], check=True)


if __name__ == "__main__":
    main()
