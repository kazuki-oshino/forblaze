"""完成文比較でのLaya追加効果。開発で閾値を固定してから比較用の全文を評価する。"""
import argparse
from datetime import datetime, timezone
import itertools
import json
from pathlib import Path
import resource

from punctuation_eval import ROOT, fingerprint
from sudachi_punctuation import Analyzer, aggregate, build_corpus, hybrid, score_text, split_punctuation
from sudachi_choice import choice_requests
from run_sudachi_punctuation import write, hashes, summarize
from run_punctuation_ensemble import load_engine, preflight, run_views


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('develop', 'evaluate'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--development', type=Path)
    parser.add_argument('--apple', type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.output.with_suffix('.jsonl').exists(): raise ValueError('既存記録は上書きしない')
    code_hashes = hashes()
    code_hashes.update({name: fingerprint(ROOT/name) for name in ('scripts/sudachi_choice.py','scripts/run_sudachi_choice.py')})
    corpus = build_corpus()
    development, policy = None, None
    if args.mode == 'evaluate':
        development = json.loads(args.development.read_text())
        if not development['complete'] or development['metadata']['hashes'] != code_hashes: raise ValueError('開発時の記録と不一致')
        policy = development['selected']
        apple_rows = [json.loads(s) for s in args.apple.read_text().splitlines()]
        apple = {(r['id'],r['punctuation']):r for r in apple_rows}
        expected = {c['id'] for values in corpus.values() for c in values}
        if len(apple) != len(apple_rows) or set(apple) != set(itertools.product(expected,(True,False))): raise ValueError('音声比較記録が不足')
        jobs = [(c,c['text'],'clean') for c in corpus['evaluation']]
        jobs += [(c,split_punctuation(apple[c['id'],False]['text'])[0],'apple_off') for c in corpus['evaluation']]
    else:
        jobs = [(c,c['text'],'clean') for c in corpus['development']]
    analyzer = Analyzer()
    engine,mx,environment = load_engine('laya')
    for case,text,source in jobs: preflight(engine,'laya',choice_requests(analyzer.analyze(text)))
    for _ in range(3): run_views(engine,mx,'laya',choice_requests(analyzer.analyze('こんにちは高須クリニックです')))
    metadata = {'started_at':datetime.now(timezone.utc).isoformat(),'environment':environment,'hashes':code_hashes,
        'protocol':'candidate_en_with_other_rule_punctuation','expected_rows':len(jobs),
        'network':'OS sandbox + offline flags + Python audit; no API',
        'development_sha256':fingerprint(args.development) if args.development else None,
        'development_finished_at':development['finished_at'] if development else None,
        'apple_sha256':fingerprint(args.apple) if args.apple else None}
    rows=[]
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.with_suffix('.jsonl').open('w') as log:
        log.write(json.dumps({'metadata':metadata},ensure_ascii=False)+'\n')
        for case,text,source in jobs:
            plan=analyzer.analyze(text); requests=choice_requests(plan)
            result=run_views(engine,mx,'laya',requests)
            row={'id':case['id'],'source':source,'gold':case['gold'],'allowed_texts':case['allowed_texts'],
                 'plan':plan,'requests':requests,'probabilities':result['answers'],'raw':result['raw'],
                 'inference_ms':result['elapsed_ms'],'recorded_at':datetime.now(timezone.utc).isoformat()}
            if policy: row['hybrid_text'],row['hybrid_changes']=hybrid(plan,row['probabilities'],**policy)
            log.write(json.dumps(row,ensure_ascii=False,allow_nan=False)+'\n');log.flush();rows.append(row)
            if len(rows)%10==0 or len(rows)==len(jobs): print(f'choice {args.mode}: {len(rows)}/{len(jobs)}',flush=True)
    output={'complete':True,'mode':args.mode,'metadata':metadata,'rows':rows,
            'finished_at':datetime.now(timezone.utc).isoformat(),
            'memory':{'rss_peak_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'mlx_peak_bytes':mx.get_peak_memory()}}
    if args.mode=='develop':
        candidates=[]
        for threshold,margin in itertools.product((.35,.5,.65,.8,.9),(0.,.15,.3)):
            candidates.append({'threshold':threshold,'margin':margin,'summary':summarize(rows,threshold,margin)['hybrid']})
        best=max(candidates,key=lambda p:(p['summary']['exact'],p['summary']['f1'],-p['summary']['fp'],
                                         -p['summary']['changes_from_rules'],p['threshold'],p['margin']))
        policy={'threshold':best['threshold'],'margin':best['margin']}
        output['selection_candidates']=candidates
        output['summaries']={'development':summarize(rows,**policy)}
    else:
        output['summaries']={source:summarize([r for r in rows if r['source']==source],**policy) for source in ('clean','apple_off')}
        output['summaries']['apple_on']=aggregate([score_text(c['gold'],apple[c['id'],True]['text']) for c in corpus['evaluation']])
        output['summaries']['apple_off_raw']=aggregate([score_text(c['gold'],apple[c['id'],False]['text']) for c in corpus['evaluation']])
    output['selected']=policy
    write(args.output,output)
    print(json.dumps({'selected':policy,'summaries':output['summaries']},ensure_ascii=False,indent=2))


if __name__=='__main__':main()
