#!/usr/bin/env python3
"""保存範囲のJev使用量を集計する。本文は表示・再送しない。"""
import argparse
import json
import math
from collections import Counter
from datetime import datetime
from pathlib import Path

# 2026-10-12確認 https://docs.typesafe.ai/models 。請求額ではなく使用量からの概算。
INPUT_USD_PER_MILLION={'jev-1.13.0':0.042}
DEFAULT_DIRECTORY=Path.home()/'Library/Logs/forblaze/jev'


def read_events(directory):
    events=[]
    invalid=0
    for path in sorted(directory.glob('requests-[0-9].jsonl')):
        if path.is_symlink() or not path.is_file():
            invalid+=1
            continue
        with path.open(encoding='utf-8',errors='replace') as stream:
            for line in stream:
                try:
                    event=json.loads(line)
                    if not (event['schemaVersion']==1 and isinstance(event['requestID'],str)
                            and event['phase'] in ('request','response')
                            and isinstance(event['model'],str)
                            and type(event['timestamp']) in (int,float) and math.isfinite(event['timestamp'])
                            and type(event['questionCount']) is int and event['questionCount']>0):
                        raise ValueError('invalid event')
                    usage=event.get('usage')
                    if usage is not None and not all(type(usage.get(k)) is int and usage[k]>=0
                                                     for k in ('inputTokens','outputTokens')):
                        raise ValueError('invalid usage')
                    events.append(event)
                except (ValueError,KeyError,TypeError,AttributeError):
                    invalid+=1
    return events,invalid


def summarize(events,since=None):
    grouped={}
    for event in events:
        pair=grouped.setdefault(event['requestID'],{})
        phase=event['phase']
        if phase not in pair or event['timestamp']>=pair[phase]['timestamp']:
            pair[phase]=event
    result=dict(api_calls=0,questions=0,input_tokens=0,output_tokens=0,usage_unknown_calls=0,
                unfinished_calls=0,missing_request_events=0,unpriced_calls=0,
                known_usage_estimated_usd=0.0,first_request_at=None,last_request_at=None)
    outcomes=Counter()
    models={}
    times=[]
    for pair in grouped.values():
        source=pair.get('request') or pair['response']
        timestamp=source['timestamp']
        if since is not None and timestamp<since:
            continue
        times.append(timestamp)
        result['api_calls']+=1
        result['questions']+=source['questionCount']
        result['missing_request_events']+=int('request' not in pair)
        response=pair.get('response')
        outcomes[response.get('outcome','unknown') if response else 'unfinished']+=1
        result['unfinished_calls']+=int(response is None)
        model=models.setdefault(source['model'],dict(api_calls=0,input_tokens=0,output_tokens=0,usage_unknown_calls=0))
        model['api_calls']+=1
        usage=response.get('usage') if response else None
        if usage is None:
            result['usage_unknown_calls']+=1
            model['usage_unknown_calls']+=1
            continue
        for field,wire in [('input_tokens','inputTokens'),('output_tokens','outputTokens')]:
            result[field]+=usage[wire]
            model[field]+=usage[wire]
        rate=INPUT_USD_PER_MILLION.get(source['model'])
        if rate is None:
            result['unpriced_calls']+=1
        else:
            result['known_usage_estimated_usd']+=usage['inputTokens']*rate/1_000_000
    if times:
        result['first_request_at']=min(times)
        result['last_request_at']=max(times)
    result['outcomes']=dict(outcomes)
    result['models']=models
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,default=DEFAULT_DIRECTORY)
    parser.add_argument('--since',help='この日時以降に開始した要求（ISO 8601、省略時は保存範囲全体）')
    parser.add_argument('--json',action='store_true')
    args=parser.parse_args()
    try:
        since=datetime.fromisoformat(args.since).timestamp() if args.since else None
    except ValueError:
        parser.error('--sinceはISO 8601の日時で指定してください')
    events,invalid=read_events(args.directory)
    result=summarize(events,since)
    result['invalid_lines_or_files']=invalid
    result['scope']='retained_logs'
    result['pricing_as_of']='2026-10-12'
    if args.json:
        print(json.dumps(result,ensure_ascii=False,indent=2))
        return
    print('保存済みJevログの集計:',args.directory)
    if not result['api_calls']:
        print('対象の記録はありません。記録開始前の使用量は分かりません。')
    else:
        first=datetime.fromtimestamp(result['first_request_at']).astimezone().isoformat(timespec='seconds')
        last=datetime.fromtimestamp(result['last_request_at']).astimezone().isoformat(timespec='seconds')
        print(f'対象要求の開始日時: {first} ～ {last}')
        print(f"API呼び出し: {result['api_calls']:,}回 / 判定候補: {result['questions']:,}件")
        print(f"使用量確認済み: 入力 {result['input_tokens']:,} / 出力 {result['output_tokens']:,} トークン")
        print(f"使用量不明: {result['usage_unknown_calls']}回（うち完了記録なし {result['unfinished_calls']}回）")
        print(f"結果: {json.dumps(result['outcomes'],ensure_ascii=False)}")
        print(f"既知の使用量・料金だけの概算: ${result['known_usage_estimated_usd']:.8f}")
        print(f"要求記録なし: {result['missing_request_events']}回 / 料金未定義モデル: {result['unpriced_calls']}回")
    print(f'読めない行・ファイル: {invalid}件')
    print('最大1MiB×10世代の保存範囲のみ。使用量不明分・削除済みログは概算に含みません。')
    print('Jev 1.13は入力100万トークンあたり$0.042・出力無料（2026-10-12確認）。請求明細とは異なります。')


if __name__=='__main__':
    main()
