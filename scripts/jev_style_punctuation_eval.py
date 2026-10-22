"""固定した句読点50例を、取得済みJev-Style 0.8BのMLXランタイムで評価する。"""

import argparse
from datetime import datetime, timezone
import importlib.metadata
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys
import time

from jev_punctuation_eval import build_jobs, summarize_records
from punctuation_eval import ROOT, PUNCTUATION, fingerprint, validate_cases

MODEL = 'Jev-Style-0.8B-Decision-v3'
REVISION = '1235ccd1c95d5228a07616cd7e323c9e0532c1dc'


def local_question(question):
    if question['type'] != 'choice':
        raise ValueError('句読点評価はchoiceのみ')
    return {'t': 'choice', 'ins': question['instructions'], 'crit': question['criteria']}


def local_jobs(cases):
    jobs = build_jobs(cases, MODEL)
    warmup, rest = jobs[:2], jobs[2:]
    return [dict(job, job_id=f'{job["job_id"]}-{repeat}')
            for repeat in range(3) for job in warmup] + rest


def decode_local(result):
    try:
        probs, choice = result['probabilities'], result['answer']
        if (choice not in PUNCTUATION or set(probs) != set(PUNCTUATION)
                or any(type(p) not in (int, float) or not math.isfinite(p) or not 0 <= p <= 1
                       for p in probs.values())
                or abs(sum(probs.values()) - 1) > 1e-6
                or probs[choice] != max(probs.values())
                or abs(result['top_probability'] - probs[choice]) > 1e-6
                or not math.isfinite(result['temperature']) or result['temperature'] <= 0
                or set(result['scores']) != set(PUNCTUATION)
                or not all(math.isfinite(s) for s in result['scores'].values())
                or type(result['input_tokens']) is not int or not 0 < result['input_tokens'] <= 25600
                or type(result['head_tokens']) is not int
                or not 0 < result['head_tokens'] <= min(2048, result['input_tokens'])
                or result.get('option_chunks', 1) != 1):
            raise ValueError('回答・確率・入力予算が不正')
        return choice
    except (KeyError, TypeError, AttributeError):
        raise ValueError('回答の形式が不正') from None


def verify_files(model_dir, precision):
    root = model_dir.resolve()
    manifest = json.loads((root / 'manifest.json').read_text())
    hashes = {}
    for name, expected in manifest['files'].items():
        if not (name.startswith(precision + '/') or '/' not in name) or name == 'README.md':
            continue
        path = (root / name).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError('モデルファイルの欠落または範囲外の参照')
        actual = fingerprint(path)
        if actual != expected['sha256']:
            raise ValueError(f'モデルのハッシュ不一致: {name}')
        hashes[name] = actual
    required = {'jev_style_decision_mlx.py', 'readout_config.json', 'release_config.json',
                f'{precision}/model.safetensors', f'{precision}/config.json', f'{precision}/tokenizer.json'}
    if not required <= set(hashes):
        raise ValueError('manifestに必須ファイルがない')
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, default=Path.home() / 'Models/jev-style-0.8b-v3-mlx')
    parser.add_argument('--cases', type=Path, default=ROOT / 'tools/laya-eval/cases.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/jev-style-eval/results.json')
    parser.add_argument('--limit', type=int, help='動作確認時だけ実行数を制限する')
    args = parser.parse_args()
    model_dir = args.model.expanduser().resolve(strict=True)
    cases = json.loads(args.cases.read_text())['cases']
    validate_cases(cases)
    jobs = local_jobs(cases)
    hashes = verify_files(model_dir, 'bf16')
    cached_revisions = {}
    for name in hashes:
        metadata = model_dir / '.cache/huggingface/download' / (name + '.metadata')
        if metadata.is_file():
            cached_revisions[name] = metadata.read_text().splitlines()[0]
    if cached_revisions and set(cached_revisions.values()) != {REVISION}:
        raise ValueError('取得済みモデルのリビジョンが評価対象と異なる')
    os.environ.update(HF_HUB_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1',
                      TRANSFORMERS_OFFLINE='1', TOKENIZERS_PARALLELISM='false')
    blocked = []

    def audit(event, arguments):
        if event in ('socket.connect', 'socket.getaddrinfo', 'socket.sendto'):
            blocked.append(event)
            raise RuntimeError('ローカル評価中のネットワーク接続を禁止')

    sys.addaudithook(audit)
    started = time.perf_counter()
    spec = importlib.util.spec_from_file_location('jev_style_runtime', model_dir / 'jev_style_decision_mlx.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    import mlx.core as mx
    import_ms = (time.perf_counter() - started) * 1000
    started = time.perf_counter()
    engine = runtime.JevStyleDecisionMLX(model_dir, precision='bf16', compute_dtype='release',
                                        split_options=False)
    mx.eval(engine.model.parameters())
    mx.synchronize()
    load_ms = (time.perf_counter() - started) * 1000
    print(f'モデル読込: {load_ms:.1f} ms、計算dtype: {engine.compute_dtype}', flush=True)
    # 同じ3候補を全て一度に読ませる。長さ超過は実行前に検出し、分割・切り詰めしない。
    lengths = []
    for job in jobs:
        for question in job['request']['questions'].values():
            rendered = engine.renderer.render(job['request']['state'], local_question(question))
            lengths.append({'input': len(rendered.ids), 'head': rendered.head_tokens})
    packages = {d.metadata['Name']: d.version for d in importlib.metadata.distributions()}
    metadata = {
        'model': MODEL, 'precision': engine.precision, 'compute_dtype': engine.compute_dtype,
        'revision': REVISION, 'cached_revisions': cached_revisions, 'model_hashes': hashes,
        'manifest_sha256': fingerprint(model_dir / 'manifest.json'),
        'cases_sha256': fingerprint(args.cases), 'script_sha256': fingerprint(Path(__file__)),
        'shared_script_hashes': {name: fingerprint(ROOT / 'scripts' / name)
                                 for name in ('punctuation_eval.py', 'jev_punctuation_eval.py')},
        'environment': {'python': platform.python_version(), 'macos': platform.mac_ver()[0],
            'chip': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
            'memory_bytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
            'packages': packages},
        'import_ms': import_ms, 'load_ms': load_ms, 'temperature': engine.temperatures['global'],
        'cache_limit_bytes': engine.cache_limit_bytes, 'split_options': engine.split_options,
        'input_token_range': [min(r['input'] for r in lengths), max(r['input'] for r in lengths)],
        'head_token_range': [min(r['head'] for r in lengths), max(r['head'] for r in lengths)],
        'seed': 20261011, 'expected_jobs': len(jobs),
        'expected_answers': sum(len(job['items']) for job in jobs),
        'offline_mode': 'HF/Transformers offline; Python audit blocks socket connect/DNS/sendto; run with OS sandbox',
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checkpoint = args.output.with_suffix('.jsonl')
    # 新規測定だけを扱う。以前の測定を上書きして混ぜない。
    if args.output.exists() or checkpoint.exists():
        raise ValueError('出力先が既に存在するため、別のoutputを指定してください')
    records = []
    with checkpoint.open('w') as stream:
        stream.write(json.dumps({'metadata': metadata}, ensure_ascii=False) + '\n')
        for job in jobs[:args.limit]:
            questions = [local_question(q) for q in job['request']['questions'].values()]
            mx.synchronize()
            start = time.perf_counter()
            result = engine.decide_many(job['request']['state'], questions)
            mx.synchronize()
            elapsed_ms = (time.perf_counter() - start) * 1000
            record = {**job, 'result': result, 'elapsed_ms': elapsed_ms,
                      'recorded_at': datetime.now(timezone.utc).isoformat()}
            # 生の応答を先に残す。異常時は正答として集計せず停止する。
            stream.write(json.dumps(record, ensure_ascii=False, allow_nan=False) + '\n')
            stream.flush()
            if len(result) != len(job['items']):
                raise ValueError('要求と回答の数が異なる')
            record['rows'] = [{**item, 'phase': job['phase'], 'job_id': job['job_id'],
                               'choice': decode_local(answer), 'choice_is_argmax': True,
                               'answer': answer, 'elapsed_ms': elapsed_ms}
                              for item, answer in zip(job['items'].values(), result)]
            records.append(record)
            if len(records) % 25 == 0 or len(records) == len(jobs):
                print(f'完了: {len(records)}/{len(jobs)} 呼出し / '
                      f'{sum(len(r["rows"]) for r in records)} 判定', flush=True)
    complete = len(records) == len(jobs)
    payload = {'metadata': metadata, 'complete': complete, 'requests': records,
               'summaries': summarize_records(cases, records) if complete else None,
               'network_attempts_blocked': blocked,
               'memory': {'rss_peak_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                          'mlx_peak_bytes': mx.get_peak_memory(), 'mlx_active_bytes': mx.get_active_memory(),
                          'mlx_cache_bytes': mx.get_cache_memory()}}
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    engine.close()
    print(json.dumps({'complete': complete, 'memory': payload['memory'],
                      'summaries': payload['summaries']}, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
