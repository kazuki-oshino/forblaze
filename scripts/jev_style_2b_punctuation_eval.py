"""Jev-Style 2Bの単発判定を、既存2組の句読点コーパスで比較する。外部APIは使わない。"""

import argparse
from datetime import datetime, timezone
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import resource
import subprocess
import sys
import time

from punctuation_eval import ROOT, PROMPTS, ORDERS, fingerprint, make_request, summarize
from punctuation_ensemble import split_cases
from jev_style_punctuation_eval import local_question, decode_local, verify_files

MODEL = 'Jev-Style-2B-Decision-v3'
REVISION = 'b86e4cbc6f420f5d7d1691299d62db272934ebf4'
SHARED = ('punctuation_eval.py', 'punctuation_ensemble.py', 'jev_style_punctuation_eval.py')


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def input_hashes():
    paths = ['tools/laya-eval/cases.json', 'tools/punctuation-ensemble/new-cases.json',
             'scripts/jev_style_2b_punctuation_eval.py'] + ['scripts/' + name for name in SHARED]
    return {p: fingerprint(ROOT / p) for p in paths}


def build_jobs(mode, groups, selected_prompt=None):
    def job(case, dataset, prompt, order_index=0, phase='primary', repeat=0):
        state, questions = make_request(case, prompt, ORDERS[order_index])
        return {'job_id': f'{dataset}-{case["id"]}-{prompt}-{phase}-{order_index}-{repeat}',
                'id': case['id'], 'dataset': dataset, 'prompt': prompt, 'order_index': order_index,
                'phase': phase, 'repeat': repeat,
                'request': {'state': state, 'question': local_question(questions['punctuation'])}}
    datasets = ('development',) if mode == 'develop' else ('original', 'holdout')
    jobs = [job(c, dataset, prompt) for dataset in datasets for c in groups[dataset] for prompt in PROMPTS]
    random.Random(20261011).shuffle(jobs)
    if mode == 'evaluate':
        # 前回追加した50例の先頭からカテゴリごとに1例。結果を見る前に診断対象を固定。
        categories, sample = set(), []
        for c in groups['holdout']:
            if c['category'] not in categories:
                categories.add(c['category'])
                sample.append(c)
        jobs += [job(c, 'holdout', selected_prompt, i, 'order') for c in sample for i in range(6)]
        jobs += [job(c, 'holdout', selected_prompt, 0, 'repeat', r) for c in sample for r in (1, 2)]
    return jobs


def select_prompts(summaries):
    return {
        'preferred': max(summaries, key=lambda p: (summaries[p]['preferred'], -summaries[p]['harmed'],
                                                   summaries[p]['acceptable'])),
        'acceptable': max(summaries, key=lambda p: (summaries[p]['acceptable'], -summaries[p]['harmed'],
                                                    summaries[p]['preferred'])),
    }


def validate_answer(result):
    choice = decode_local(result)
    if (result.get('model') != MODEL or result.get('backend') != 'mlx'
            or type(result.get('state_tokens')) is not int or result['state_tokens'] <= 0
            or result['state_tokens'] + result['head_tokens'] != result['input_tokens']
            or result.get('catalogue_overflow') is not False or result.get('blocks') != 2):
        # 本コーパスは短文。2Bの長文カタログ分割を使うケースは測定に混ぜない。
        raise ValueError('モデルまたは短文入力の形式が不正')
    return choice


def run_single(engine, mx, request):
    engine.engine.reset()
    mx.synchronize()
    started = time.perf_counter()
    result = engine.decide(request['state'], request['question'])
    mx.synchronize()
    elapsed = (time.perf_counter() - started) * 1000
    if engine.last_timing['state_reused']:
        raise ValueError('単発測定でstateのキャッシュが再利用された')
    return {'result': result, 'elapsed_ms': elapsed, 'timing': dict(engine.last_timing)}


def summarize_jobs(groups, records):
    return {dataset: {prompt: summarize(groups[dataset], [r for r in records
                if r['dataset'] == dataset and r['prompt'] == prompt and r['phase'] == 'primary'])
                for prompt in PROMPTS}
            for dataset in dict.fromkeys(r['dataset'] for r in records)}


def diagnose(records, selected_prompt):
    primary = {r['id']: r['choice'] for r in records if r['phase'] == 'primary'
               and r['dataset'] == 'holdout' and r['prompt'] == selected_prompt}
    order_rows = [r for r in records if r['phase'] == 'order']
    ids = sorted({r['id'] for r in order_rows})
    return {'ids': ids,
            'order_sensitive_ids': [i for i in ids if len({r['choice'] for r in order_rows if r['id'] == i}) > 1],
            'canonical_changed_ids': [r['id'] for r in order_rows if r['order_index'] == 0 and r['choice'] != primary[r['id']]],
            'repeat_changed_ids': sorted({r['id'] for r in records if r['phase'] == 'repeat' and r['choice'] != primary[r['id']]})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['develop', 'evaluate'])
    parser.add_argument('--model', type=Path, default=Path.home() / 'Models/jev-style-2b-v3-mlx')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--development', type=Path)
    args = parser.parse_args()
    checkpoint = args.output.with_suffix('.jsonl')
    if args.output.exists() or checkpoint.exists():
        raise ValueError('既存の結果を上書きしない。新しいoutputを指定する')
    groups, hashes = split_cases(), input_hashes()
    development = None
    if args.mode == 'evaluate':
        if args.development is None:
            raise ValueError('開発30例で質問を選択した記録が必要')
        development = json.loads(args.development.read_text())
        if (development.get('complete') is not True or development.get('mode') != 'develop'
                or development['metadata']['input_hashes'] != hashes
                or development['metadata']['revision'] != REVISION):
            raise ValueError('開発記録の完了状態・入力・モデルが異なる')
        if development['selected'] != select_prompts(development['summaries']['development']):
            raise ValueError('保存された選択と開発結果が不一致')
    selected = development['selected'] if development else None
    jobs = build_jobs(args.mode, groups, selected['preferred'] if selected else None)
    model_dir = args.model.expanduser().resolve(strict=True)
    verified = verify_files(model_dir, 'bf16')
    if 'bf16/macjev_norms_fp32.safetensors' not in verified:
        raise ValueError('2Bの必須normファイルがmanifestにない')
    revisions = {}
    for name in verified:
        meta = model_dir / '.cache/huggingface/download' / (name + '.metadata')
        revisions[name] = meta.read_text().splitlines()[0]
    if set(revisions.values()) != {REVISION}:
        raise ValueError('ダウンロードのリビジョンが不一致')
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                      HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')
    blocked = []
    def audit(event, arguments):
        if event in ('socket.connect', 'socket.getaddrinfo', 'socket.sendto'):
            blocked.append(event)
            raise RuntimeError('ローカル評価中のネットワーク接続を禁止')
    sys.addaudithook(audit)
    spec = importlib.util.spec_from_file_location('jev_style_2b_runtime', model_dir / 'jev_style_decision_mlx.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    import mlx.core as mx
    started = time.perf_counter()
    engine = runtime.JevStyleDecisionMLX(model_dir, precision='bf16', compute_dtype='release')
    mx.eval(engine.engine.model.parameters())
    mx.synchronize()
    load_ms = (time.perf_counter() - started) * 1000
    lengths = []
    for j in jobs:
        rendered = engine.renderer.render(j['request']['state'], j['request']['question'])
        if rendered.catalogue_overflow or len(rendered.blocks) != 2:
            raise ValueError('想定外の入力分割')
        lengths.append([rendered.input_tokens, rendered.head_tokens])
    warmup = [run_single(engine, mx, jobs[0]['request']) for _ in range(3)]
    for r in warmup: validate_answer(r['result'])
    metadata = {'model': MODEL, 'revision': REVISION, 'model_hashes': verified,
        'cached_revisions': revisions, 'input_hashes': hashes,
        'started_at': datetime.now(timezone.utc).isoformat(),
        'development_sha256': fingerprint(args.development) if development else None,
        'development_finished_at': development['finished_at'] if development else None,
        'selection': '開発30例の好み一致を主目的、許容一致を副目的として4形式から別々に選ぶ。同点は改悪の少なさ、もう一方の一致、定義順。',
        'precision': engine.precision, 'compute_dtype': engine.compute_dtype,
        'compute_dtype_note': 'nullは配布設定のネイティブBF16。RMSNormとreadoutは配布元がFP32へ補正。',
        'load_ms': load_ms, 'warmup': warmup,
        'temperature': engine.default_temperature, 'state_cache': '各単発呼出し前にreset',
        'input_token_range': [min(n[0] for n in lengths), max(n[0] for n in lengths)],
        'head_token_range': [min(n[1] for n in lengths), max(n[1] for n in lengths)],
        'environment': {'python': platform.python_version(), 'macos': platform.mac_ver()[0],
            'chip': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
            'memory_bytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
            'packages': {d.metadata['Name']: d.version for d in importlib.metadata.distributions()}},
        'network': 'OS sandbox + offline environment + Python audit; no API',
        'expected_rows': len(jobs)}
    records = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with checkpoint.open('w') as stream:
        stream.write(json.dumps({'metadata': metadata}, ensure_ascii=False) + '\n')
        for job in jobs:
            row = {**job, **run_single(engine, mx, job['request']),
                   'recorded_at': datetime.now(timezone.utc).isoformat()}
            stream.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')
            stream.flush()
            row['choice'] = validate_answer(row['result'])
            records.append(row)
            if len(records) % 25 == 0 or len(records) == len(jobs):
                print(f'{args.mode}: {len(records)}/{len(jobs)}', flush=True)
    summaries = summarize_jobs(groups, records)
    if args.mode == 'develop': selected = select_prompts(summaries['development'])
    output = {'mode': args.mode, 'complete': True, 'metadata': metadata,
              'finished_at': datetime.now(timezone.utc).isoformat(), 'selected': selected,
              'rows': records, 'summaries': summaries,
              'diagnostics': diagnose(records, selected['preferred']) if args.mode == 'evaluate' else None,
              'network_attempts_blocked': blocked,
              'memory': {'rss_peak_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                         'mlx_peak_bytes': mx.get_peak_memory(), 'mlx_active_bytes': mx.get_active_memory()}}
    write(args.output, output)
    engine.close()
    print(json.dumps({k: output[k] for k in ('selected', 'summaries', 'diagnostics', 'memory')},
                     ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
