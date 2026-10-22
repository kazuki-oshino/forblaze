"""既存合成文からKyoko音声と末尾1秒無音版を作る。音声は再生しない。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from sudachi_punctuation import build_corpus


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None: raise RuntimeError('無音追加にはffmpegが必要')
    corpus = build_corpus()
    jobs, manifest = [], []
    for dataset, cases in corpus.items():
        for case in cases:
            path = (args.output / (case['id'] + '.aiff')).resolve()
            padded = path.with_suffix('.wav')
            subprocess.run(['say', '-v', 'Kyoko', '-r', '180', '-o', str(path), case['gold']], check=True)
            subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-i', str(path), '-af', 'apad=pad_dur=1',
                            '-c:a', 'pcm_s16le', str(padded)], check=True)
            jobs.append({'id': case['id'], 'dataset': dataset, 'path': str(padded)})
            manifest.append({'id': case['id'], 'dataset': dataset, 'text': case['gold'], 'voice': 'Kyoko',
                'rate': 180, 'trailing_silence_seconds': 1.0,
                'original_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                'padded_sha256': hashlib.sha256(padded.read_bytes()).hexdigest()})
    for name, data in [('corpus.json', corpus), ('audio-jobs.json', jobs), ('audio-manifest.json', manifest)]:
        (args.output / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__': main()
