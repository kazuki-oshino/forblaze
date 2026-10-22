"""ローカルモデルの多角的な句読点評価。探索→開発データで選択→固定して検証する。"""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import importlib.metadata
import importlib.util
import itertools
import json
import math
import os
from pathlib import Path
import platform
import random
import sys
import time

from punctuation_eval import ROOT, ORDERS, fingerprint, make_request, summarize
from punctuation_ensemble import (LABELS, PROTOCOLS, views, split_cases, features, combine,
                                   fit_ridge, predict_ridge, choose)
from jev_style_punctuation_eval import verify_files


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')


def load_engine(backend):
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                      HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')
    def audit(event, args):
        if event in ('socket.connect', 'socket.getaddrinfo', 'socket.sendto'):
            raise RuntimeError('本実験はネットワーク接続禁止')
    sys.addaudithook(audit)
    import mlx.core as mx
    start = time.perf_counter()
    if backend == 'laya':
        import laya_mlx
        model = Path.home() / 'Models/laya-multilingual-mlx'
        manifest = json.loads((model / 'manifest.json').read_text())
        hashes = {}
        for name, expected in manifest['files'].items():
            path = (model / name).resolve(strict=True)
            if not path.is_relative_to(model) or fingerprint(path) != expected['sha256']:
                raise ValueError('Layaのファイル検証に失敗')
            hashes[name] = expected['sha256']
        engine = laya_mlx.load(model, dtype='float16', device='gpu', batch_size=5)
        dtype = 'float16'
    else:
        model = Path.home() / 'Models/jev-style-0.8b-v3-mlx'
        hashes = verify_files(model, 'bf16')
        spec = importlib.util.spec_from_file_location('jev_style_runtime', model / 'jev_style_decision_mlx.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        engine = module.JevStyleDecisionMLX(model, precision='bf16', compute_dtype='release', split_options=False)
        mx.eval(engine.model.parameters())
        dtype = engine.compute_dtype
    mx.synchronize()
    return engine, mx, {'backend': backend, 'model_hashes': hashes, 'dtype': dtype,
        'load_ms': (time.perf_counter()-start)*1000, 'python': platform.python_version(),
        'packages': {d.metadata['Name']: d.version for d in importlib.metadata.distributions()}}


def preflight(engine, backend, requests):
    for view in requests:
        q = view['question']
        if backend == 'laya':
            from laya_mlx.common import render_options
            items, internal = engine.prepare(view['state'], {'v': q})
            if items[0]['state_stats']['truncated']:
                raise ValueError('stateの切り詰め')
            opts = render_options(internal[0])
            lens = [len(engine.tok(' '+s, add_special_tokens=False)['input_ids']) for s in opts]
            head = len(engine.tok(q['type']+' question: '+q['instructions'], add_special_tokens=False)['input_ids'])
            if max(lens) > 48 or head + sum(x+1 for x in lens) > engine.cfg['head_max_len']:
                raise ValueError('質問または選択肢の切り詰め')
            if items[0]['options']['options_distinct'] != len(opts):
                raise ValueError('選択肢のトークン表現が重複')
        else:
            engine.renderer.render(view['state'], {'t': q['type'], 'ins': q['instructions'],
                                                   'crit': q.get('criteria')})


def run_views(engine, mx, backend, requests):
    # 同じstateの独立した質問は一緒に送る。Layaは最大5問のGPUバッチ、0.8Bは配布実装の逐次処理。
    groups = defaultdict(list)
    for index, view in enumerate(requests): groups[view['state']].append((index, view['question']))
    answers, raw = [None] * len(requests), []
    mx.synchronize()
    start = time.perf_counter()
    for state, entries in groups.items():
        if backend == 'laya':
            result = engine.predict(state, {str(i): q for i, q in entries})
            if result['usage']['truncated']:
                raise ValueError('推論時の切り詰め')
            for i, q in entries:
                a = result['answers'][str(i)]
                answers[i] = {'false': 1-a['noul'], 'true': a['noul']} if q['type']=='noul' else dict(a['probabilities'])
        else:
            result = engine.decide_many(state, [{'t': q['type'], 'ins': q['instructions'],
                                                 'crit': q.get('criteria')} for _, q in entries])
            for (i, q), a in zip(entries, result): answers[i] = dict(a['probabilities'])
        raw.append({'state': state, 'indices': [i for i, _ in entries], 'result': result})
    mx.synchronize()
    elapsed = (time.perf_counter()-start)*1000
    for view, probabilities in zip(requests, answers):
        expected = {'false', 'true'} if view['question']['type']=='noul' else set(view['question']['criteria'])
        if (set(probabilities) != expected or any(not math.isfinite(p) or not 0 <= p <= 1 for p in probabilities.values())
                or abs(sum(probabilities.values())-1) > .001):
            raise ValueError('不正なモデル確率')
        # Layaの4桁丸めによる和の誤差だけを揃える。元の応答はrawへ残す。
        total = sum(probabilities.values())
        for key in probabilities: probabilities[key] /= total
    return {'answers': answers, 'raw': raw, 'elapsed_ms': elapsed}


def score_row(row, policy):
    return (combine(row, policy['count']) if policy['kind']=='rule'
            else predict_ridge(policy['model'], features(row, policy['count'])))


def policy_rank(candidate, objective):
    s = candidate['cv']
    quality = ((s['acceptable'], -s['harmed'], s['preferred']) if objective == 'accuracy'
               else (s['acceptable'] - 2*s['harmed'], s['preferred'], s['acceptable'], -s['harmed']))
    return (*quality, candidate['kind']=='rule', candidate['alpha'] or 0,
            -candidate['margin'], -PROTOCOLS.index(candidate['protocol']))


def select_policy(exploration, output, objective='balanced'):
    cases = split_cases()['development']
    ids = {c['id'] for c in cases}
    if exploration['dataset'] != 'development' or {r['id'] for r in exploration['rows']} != ids:
        raise ValueError('方式選択に使えるのは開発用30例だけ')
    by_key = {(r['id'], r['protocol']): r for r in exploration['rows']}
    if len(by_key) != len(exploration['rows']) or set(by_key) != set(itertools.product(ids, PROTOCOLS)):
        raise ValueError('開発用の質問方式が不足または重複')
    for c in cases:
        for protocol in PROTOCOLS:
            if by_key[(c['id'], protocol)]['requests'] != views(c, protocol):
                raise ValueError('保存済みの質問が現在の定義と異なる')
    categories, folds = defaultdict(list), {}
    for c in cases:
        folds[c['id']] = len(categories[c['category']]) % 3
        categories[c['category']].append(c['id'])
    candidates = []
    for protocol, count, alpha, margin in itertools.product(PROTOCOLS, (3, 5), (None, .1, 1., 10.), (0., .1, .2, .4)):
        policy = {'protocol': protocol, 'count': count, 'kind': 'rule' if alpha is None else 'ridge',
                  'alpha': alpha, 'margin': margin}
        predicted = []
        for fold in range(3):
            training = [c for c in cases if folds[c['id']] != fold]
            fitted = dict(policy)
            if alpha is not None:
                fitted['model'] = fit_ridge([features(by_key[(c['id'], protocol)], count) for c in training],
                                            [c['preferred'] for c in training], alpha)
            for c in cases:
                if folds[c['id']] == fold:
                    row = by_key[(c['id'], protocol)]
                    scores = score_row(row, fitted)
                    predicted.append({'id': c['id'], 'choice': choose(c, scores, margin),
                                      'elapsed_ms': 0., 'scores': scores})
        candidates.append({**policy, 'cv': summarize(cases, predicted), 'predictions': predicted})
    selected = []
    for count in (3, 5):
        winner = max((c for c in candidates if c['count']==count), key=lambda c: policy_rank(c, objective))
        policy = {k: v for k, v in winner.items() if k != 'predictions'}
        if policy['kind']=='ridge':
            policy['model'] = fit_ridge([features(by_key[(c['id'], policy['protocol'])], count) for c in cases],
                                       [c['preferred'] for c in cases], policy['alpha'])
        selected.append(policy)
    payload = {'frozen_at': datetime.now(timezone.utc).isoformat(), 'backend': exploration['backend'],
               'development_ids': sorted(ids), 'original_cases_sha256': fingerprint(ROOT/'tools/laya-eval/cases.json'),
               'new_cases_sha256': fingerprint(ROOT/'tools/punctuation-ensemble/new-cases.json'),
               'core_sha256': fingerprint(ROOT/'scripts/punctuation_ensemble.py'),
               'objective_name': objective,
               'objective': ('3分割CVの許容一致を最大化。同点は改悪の少なさ、好み一致、単純な規則、強い正則化、低い見送り閾値の順。'
                             if objective == 'accuracy' else
                             '3分割CVの(許容一致数-2*改悪数)を最大化。同点は好み一致、許容一致、改悪の少なさ、単純な規則、強い正則化、低い見送り閾値の順。'),
               'selected': selected, 'candidates': candidates}
    write(output, payload)
    print(json.dumps({'selected': selected}, ensure_ascii=False, indent=2), flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=['explore', 'select', 'evaluate'])
    p.add_argument('--backend', choices=['laya', 'jev-style'], required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--input', type=Path)
    p.add_argument('--protocols', nargs='+', choices=PROTOCOLS, default=PROTOCOLS)
    p.add_argument('--objective', choices=['balanced', 'accuracy'], default='balanced')
    args = p.parse_args()
    if args.output.exists() or args.output.with_suffix('.jsonl').exists():
        raise ValueError('既存の結果を上書きしない。別のoutputを指定する')
    if args.mode == 'select':
        exploration = json.loads(args.input.read_text())
        if exploration['backend'] != args.backend:
            raise ValueError('選択対象のモデルが異なる')
        select_policy(exploration, args.output, args.objective)
        return
    groups = split_cases()
    policies = None
    if args.mode == 'explore':
        cases = groups['development']
        jobs = [(c, protocol, 5, 'development') for c in cases for protocol in args.protocols]
    else:
        policies = json.loads(args.input.read_text())
        if (policies['backend'] != args.backend or policies['core_sha256'] != fingerprint(ROOT/'scripts/punctuation_ensemble.py')
                or policies['new_cases_sha256'] != fingerprint(ROOT/'tools/punctuation-ensemble/new-cases.json')
                or policies['original_cases_sha256'] != fingerprint(ROOT/'tools/laya-eval/cases.json')):
            raise ValueError('固定した方式と入力・コードが異なる')
        cases = groups['original'] + groups['holdout']
        jobs = [(c, policy['protocol'], policy['count'], dataset)
                for dataset in ('original', 'holdout') for c in groups[dataset] for policy in policies['selected']]
        jobs += [(c, 'baseline', 1, dataset) for dataset in ('original', 'holdout') for c in groups[dataset]]
    random.Random(20261012).shuffle(jobs)
    def requests_for(case, protocol, count):
        if protocol != 'baseline': return views(case, protocol)[:count]
        state, questions = make_request(case, 'candidate_en' if args.backend=='laya' else 'ja', ORDERS[0])
        return [{'state': state, 'question': questions['punctuation']}]
    engine, mx, environment = load_engine(args.backend)
    for case, protocol, count, _ in jobs:
        preflight(engine, args.backend, requests_for(case, protocol, count))
    warmup = [run_views(engine, mx, args.backend, views(cases[0], 'factors_en')) for _ in range(3)]
    metadata = {'backend': args.backend, 'environment': environment,
                'started_at': datetime.now(timezone.utc).isoformat(), 'network': 'OS sandbox + Python audit; no API',
                'core_sha256': fingerprint(ROOT/'scripts/punctuation_ensemble.py'),
                'runner_sha256': fingerprint(Path(__file__)),
                'original_cases_sha256': fingerprint(ROOT/'tools/laya-eval/cases.json'),
                'new_cases_sha256': fingerprint(ROOT/'tools/punctuation-ensemble/new-cases.json'),
                'policy_sha256': fingerprint(args.input) if policies else None, 'warmup': warmup}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    with args.output.with_suffix('.jsonl').open('w') as stream:
        stream.write(json.dumps({'metadata': metadata}, ensure_ascii=False)+'\n')
        for case, protocol, count, dataset in jobs:
            requests = requests_for(case, protocol, count)
            row = {'id': case['id'], 'protocol': protocol, 'count': count, 'dataset': dataset,
                   'requests': requests, **run_views(engine, mx, args.backend, requests)}
            if policies:
                if protocol == 'baseline':
                    scores = [row['answers'][0][label] for label in LABELS]
                    row['choice'] = LABELS[max(range(3), key=lambda i: scores[i])]
                else:
                    policy = next(p for p in policies['selected'] if p['count']==count)
                    scores = score_row(row, policy)
                    row['choice'] = choose(case, scores, policy['margin'])
                row['combined_scores'] = scores
            stream.write(json.dumps(row, ensure_ascii=False, allow_nan=False)+'\n')
            stream.flush()
            rows.append(row)
            if len(rows)%25==0: print(f'{args.backend} {args.mode}: {len(rows)}/{len(jobs)}', flush=True)
    summary = None
    if policies:
        summary = {dataset: {str(count): summarize(groups[dataset], [r for r in rows if r['dataset']==dataset and r['count']==count])
                            for count in (1, 3, 5)} for dataset in ('original', 'holdout')}
    payload = {'backend': args.backend, 'dataset': 'development' if args.mode=='explore' else 'validation',
               'metadata': metadata, 'policies': policies['selected'] if policies else None,
               'rows': rows, 'summaries': summary,
               'mlx_peak_bytes': mx.get_peak_memory()}
    write(args.output, payload)
    print(json.dumps({'complete': True, 'rows': len(rows), 'summaries': summary}, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
