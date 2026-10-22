"""SudachiルールとLayaの追加効果を、全文復元と同一合成音声で評価する。"""
import argparse
from datetime import datetime, timezone
import importlib.metadata
import itertools
import json
from pathlib import Path
import resource
import sys
import time

from punctuation_eval import ROOT, fingerprint, percentile
from sudachi_punctuation import Analyzer, aggregate, build_corpus, hybrid, requests_for, score_text, split_punctuation
from run_punctuation_ensemble import load_engine, preflight, run_views


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def hashes():
    names = ('scripts/sudachi_punctuation.py', 'scripts/run_sudachi_punctuation.py',
             'scripts/run_punctuation_ensemble.py', 'scripts/punctuation_ensemble.py',
             'scripts/punctuation_eval.py', 'tools/laya-eval/cases.json',
             'tools/punctuation-ensemble/new-cases.json')
    return {name: fingerprint(ROOT / name) for name in names}


def summarize(rows, threshold, margin):
    output = {}
    for method in ('unpunctuated', 'rules', 'hybrid'):
        scores, elapsed, changes = [], [], 0
        for row in rows:
            if method == 'unpunctuated':
                text, ms = row['plan']['text'], 0
            elif method == 'rules':
                text, ms = row['plan']['rule_text'], row['plan']['analysis_ms']
            else:
                text, changed = hybrid(row['plan'], row['probabilities'], threshold, margin)
                changes += changed
                ms = row['plan']['analysis_ms'] + row['inference_ms']
            scores.append(score_text(row['gold'], text)); elapsed.append(ms)
        output[method] = {**aggregate(scores), 'p50_ms': percentile(elapsed, .5), 'p95_ms': percentile(elapsed, .95),
                          'changes_from_rules': changes if method == 'hybrid' else 0}
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('develop', 'evaluate'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--development', type=Path)
    parser.add_argument('--apple', type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.output.with_suffix('.jsonl').exists():
        raise ValueError('既存出力は上書きしない')
    corpus, code_hashes = build_corpus(), hashes()
    policy, development = None, None
    if args.mode == 'evaluate':
        development = json.loads(args.development.read_text())
        if not development['complete'] or development['metadata']['hashes'] != code_hashes:
            raise ValueError('開発時から入力またはコードが変わった')
        policy = development['selected']
    analyzer = Analyzer()
    engine, mx, environment = load_engine('laya')
    import sudachidict_core
    dictionary_path = Path(sudachidict_core.__file__).parent / 'resources/system.dic'
    jobs = []
    apple = None
    if args.mode == 'develop':
        jobs = [(c, c['text'], 'clean') for c in corpus['development']]
    else:
        apple_rows = [json.loads(line) for line in args.apple.read_text().splitlines()]
        apple = {(r['id'], r['punctuation']): r for r in apple_rows}
        expected = {c['id'] for values in corpus.values() for c in values}
        if len(apple) != len(apple_rows) or set(apple) != set(itertools.product(expected, (True, False))):
            raise ValueError('Apple認識のON/OFFまたは件数が不足')
        jobs = [(c, c['text'], 'clean') for c in corpus['evaluation']]
        jobs += [(c, split_punctuation(apple[c['id'], False]['text'])[0], 'apple_off') for c in corpus['evaluation']]
    # 推論前に全候補・全質問の予算を検査。期待結果は質問に渡さない。
    for case, text, source in jobs:
        plan = analyzer.analyze(text)
        requests = [q for group in requests_for(plan) for q in group]
        preflight(engine, 'laya', requests)
    warmup = requests_for(analyzer.analyze('こんにちは高須クリニックです'))
    for _ in range(3): run_views(engine, mx, 'laya', warmup[0])
    metadata = {'started_at': datetime.now(timezone.utc).isoformat(), 'environment': environment,
        'hashes': code_hashes, 'dictionary_sha256': fingerprint(dictionary_path),
        'dictionary_bytes': dictionary_path.stat().st_size,
        'sudachipy': importlib.metadata.version('SudachiPy'), 'sudachidict_core': importlib.metadata.version('SudachiDict-core'),
        'network': 'OS sandbox + offline flags + Python audit; no hosted inference',
        'apple_sha256': fingerprint(args.apple) if args.apple else None,
        'development_sha256': fingerprint(args.development) if args.development else None,
        'development_finished_at': development['finished_at'] if development else None,
        'latency': '形態素解析とルール処理、全候補の3問判定を含む。モデル読込・事前予算検査・採点は除く。',
        'expected_rows': len(jobs)}
    rows = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.with_suffix('.jsonl').open('w') as checkpoint:
        checkpoint.write(json.dumps({'metadata': metadata}, ensure_ascii=False) + '\n')
        for case, text, source in jobs:
            plan = analyzer.analyze(text)
            grouped = requests_for(plan)
            requests = [q for group in grouped for q in group]
            result = run_views(engine, mx, 'laya', requests)
            probabilities = [dict(zip(('comma', 'period', 'none'), [a['true'] for a in result['answers'][i:i + 3]]))
                             for i in range(0, len(result['answers']), 3)]
            row = {'id': case['id'], 'source': source, 'gold': case['gold'], 'allowed_texts': case['allowed_texts'],
                'plan': plan, 'requests': requests, 'probabilities': probabilities, 'raw': result['raw'],
                'inference_ms': result['elapsed_ms'], 'recorded_at': datetime.now(timezone.utc).isoformat()}
            if policy:
                row['hybrid_text'], row['hybrid_changes'] = hybrid(plan, probabilities, policy['threshold'], policy['margin'])
            checkpoint.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n'); checkpoint.flush()
            rows.append(row)
            if len(rows) % 10 == 0 or len(rows) == len(jobs): print(f'{args.mode}: {len(rows)}/{len(jobs)}', flush=True)
    output = {'complete': True, 'mode': args.mode, 'metadata': metadata, 'rows': rows,
              'finished_at': datetime.now(timezone.utc).isoformat(),
              'memory': {'rss_peak_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss, 'mlx_peak_bytes': mx.get_peak_memory()}}
    if args.mode == 'develop':
        candidates = []
        for threshold, margin in itertools.product((.5, .65, .8, .9, .98), (0., .15, .3)):
            summary = summarize(rows, threshold, margin)['hybrid']
            candidates.append({'threshold': threshold, 'margin': margin, 'summary': summary})
        # 全文の好み一致、句読点F1、不要挿入、変更量の順で開発例だけから選ぶ。
        best = max(candidates, key=lambda p: (p['summary']['exact'], p['summary']['f1'],
                   -p['summary']['fp'], -p['summary']['changes_from_rules'], p['threshold'], p['margin']))
        output['selected'] = policy = {'threshold': best['threshold'], 'margin': best['margin']}
        output['selection_candidates'] = candidates
        output['summaries'] = {'development': summarize(rows, **policy)}
    else:
        output['selected'] = policy
        output['summaries'] = {source: summarize([r for r in rows if r['source'] == source], **policy)
                               for source in ('clean', 'apple_off')}
        output['summaries']['apple_on'] = aggregate([score_text(c['gold'], apple[c['id'], True]['text']) for c in corpus['evaluation']])
        output['summaries']['apple_off_raw'] = aggregate([score_text(c['gold'], apple[c['id'], False]['text']) for c in corpus['evaluation']])
    write(args.output, output)
    print(json.dumps({'selected': policy, 'summaries': output['summaries'], 'memory': output['memory']}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
