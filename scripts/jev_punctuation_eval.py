"""Layaと同じ合成50例をTypeSafeの本家Jev APIで比較する。実アプリとは接続しない。"""

import argparse
from datetime import datetime, timezone
import importlib.metadata
import itertools
import json
import math
import os
from pathlib import Path
import platform
import random
import shlex
import time

from punctuation_eval import (ROOT, ORDERS, PROMPTS, PUNCTUATION, fingerprint,
                              make_request, summarize, validate_cases)

ENDPOINT = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-1.13.0"


def load_key(path):
    # .envをシェルで実行せず、対象キーだけを読む。値の展開はしない。
    for line in path.read_text().splitlines():
        name, separator, value = line.strip().removeprefix('export ').partition('=')
        if separator and name.strip() == 'TYPESAFE_API_KEY':
            try:
                parts = shlex.split(value, comments=True)
            except ValueError:
                raise ValueError('TYPESAFE_API_KEYの引用符が不正') from None
            if len(parts) == 1 and parts[0] and not any(c.isspace() for c in parts[0]):
                return parts[0]
            raise ValueError('TYPESAFE_API_KEYが空または不正')
    raise ValueError('TYPESAFE_API_KEYが見つからない')


def safe_json(value, key):
    text = json.dumps(value, ensure_ascii=False, allow_nan=False)
    if key in text:
        raise ValueError('認証情報を含む記録の保存を拒否')
    return text


def decode_result(result, question_ids, model):
    def probability(value):
        return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1

    try:
        if result['model'] != model or set(result['answers']) != set(question_ids):
            raise ValueError('モデルまたは回答IDが不一致')
        if any(type(result['usage'][key]) is not int or result['usage'][key] < 0
               for key in ('input_tokens', 'output_tokens')):
            raise ValueError('トークン数が不正')
        choices = {}
        for key, answer in result['answers'].items():
            probs, choice = answer['probabilities'], answer['choice']
            if (answer['type'] != 'choice' or choice not in PUNCTUATION
                    or set(probs) != set(PUNCTUATION)
                    or not all(probability(p) for p in probs.values())
                    # APIは小数2桁の値も返す。3選択肢の丸め誤差だけを許容する。
                    or abs(sum(probs.values()) - 1) > .015 + 1e-12
                    or not probability(answer['confidence'])):
                raise ValueError('回答の形式・確率が不正')
            choices[key] = choice
        return choices
    except (KeyError, TypeError, AttributeError):
        raise ValueError('回答の形式が不正') from None


def run_request(client, payload, key, sleep=time.sleep):
    start = time.perf_counter()
    retries = []
    for attempt in range(4):
        sent = time.perf_counter()
        # 認証ヘッダーはclientの呼出し時だけに付け、返却・保存しない。
        response = client.post(ENDPOINT, json=payload,
                               headers={'Authorization': f'Bearer {key}'})
        elapsed_ms = (time.perf_counter() - sent) * 1000
        if response.status_code == 200:
            return {'result': response.json(), 'elapsed_ms': elapsed_ms,
                    'total_elapsed_ms': (time.perf_counter() - start) * 1000,
                    'retry_statuses': retries}
        if response.status_code not in (429, 529) or attempt == 3:
            # サーバーのエラー本文は資格情報を反射する可能性があるため記録しない。
            raise RuntimeError(f'Jev API HTTP {response.status_code}')
        retries.append(response.status_code)
        try:
            delay = max(2 ** attempt, float(response.headers.get('retry-after', 0)))
        except ValueError:
            raise RuntimeError('Retry-Afterを秒数として解釈できないため停止') from None
        if not math.isfinite(delay) or delay > 60:
            raise RuntimeError('Retry-Afterが60秒を超えるため停止。後から同じコマンドで再開可能')
        print(f'HTTP {response.status_code}: {delay:g}秒後に再試行', flush=True)
        sleep(delay)


def build_jobs(cases, model):
    def job(job_id, phase, case, specs):
        items, questions = {}, {}
        states = []
        for prompt, order_index in specs:
            key = 'punctuation' if len(specs) == 1 else f'{prompt}_{order_index}'
            state, request_questions = make_request(case, prompt, ORDERS[order_index])
            states.append(state)
            questions[key] = request_questions['punctuation']
            items[key] = {'id': case['id'], 'prompt': prompt, 'order_index': order_index,
                          'order': list(ORDERS[order_index])}
        if len(set(states)) != 1:
            raise ValueError('一括送信では同じstateだけを共有する')
        return {'job_id': job_id, 'phase': phase, 'items': items,
                'request': {'model': model, 'state': states[0], 'questions': questions}}

    jobs = [job(f'warmup-{p}', 'warmup', cases[0], [(p, 0)])
            for p in ('ja', 'candidate_ja')]
    # 主評価は1問/HTTP要求。前回と同じ入力を送り、通信込みの待ち時間を測る。
    primary = [job(f'primary-{c["id"]}-{p}', 'primary', c, [(p, 0)])
               for c, p in itertools.product(cases, PROMPTS)]
    random.Random(20261011).shuffle(primary)
    jobs.extend(primary)
    # 順序検査は同じstateの12問をまとめる。基本順序も含め一括/単独の差を測る。
    order_jobs = [job(f'orders-{c["id"]}-{pair[0]}', 'orders', c,
                      list(itertools.product(pair, range(6))))
                  for c in cases for pair in (('ja', 'en'), ('candidate_ja', 'candidate_en'))]
    random.Random(20261011).shuffle(order_jobs)
    jobs.extend(order_jobs)
    jobs.extend(job(f'repeat-{repeat}-{c["id"]}-{p}', 'repeat', c, [(p, 0)])
                for repeat, c, p in itertools.product(range(2), cases, ('ja', 'candidate_ja')))
    return jobs


def read_checkpoint(path, metadata):
    if not path.exists():
        return []
    with path.open() as stream:
        previous = json.loads(next(stream))['metadata']
        # ログ処理の修正後も再利用できるが、モデル・コーパス・質問の変更は拒否する。
        # 実際のrequestもmainで全件比較し、旧ハッシュはcheckpoint内に保持する。
        comparable = lambda value: {k: v for k, v in value.items() if k != 'script_sha256'}
        if comparable(previous) != comparable(metadata):
            raise ValueError('再開用記録の設定・入力が異なる。別のoutputを指定する')
        rows = [json.loads(line) for line in stream]
    if len({row['job_id'] for row in rows}) != len(rows):
        raise ValueError('再開用記録に重複IDがある')
    return rows


def decode_rows(record):
    choices = decode_result(record['result'], record['items'], MODEL)
    return [{**item, 'phase': record['phase'], 'job_id': record['job_id'],
             'choice': choices[qid], 'elapsed_ms': record['elapsed_ms'],
             # APIのchoiceを採点し、確率の最大値との不一致は独立に記録する。
             'choice_is_argmax': record['result']['answers'][qid]['probabilities'][choices[qid]]
                 == max(record['result']['answers'][qid]['probabilities'].values()),
             'answer': record['result']['answers'][qid]}
            for qid, item in record['items'].items()]


def summarize_records(cases, records):
    rows = [row for record in records for row in record['rows']]
    summaries = {}
    for prompt in PROMPTS:
        primary = [r for r in rows if r['prompt'] == prompt and r['phase'] == 'primary']
        orders = [r for r in rows if r['prompt'] == prompt and r['phase'] == 'orders']
        primary_choices = {r['id']: r['choice'] for r in primary}
        summaries[prompt] = {
            'non_argmax_answer_count': sum(not r['choice_is_argmax'] for r in rows if r['prompt'] == prompt),
            'canonical': summarize(cases, primary),
            'evaluation_only': summarize(cases, [r for r in primary if next(
                c for c in cases if c['id'] == r['id'])['split'] == 'evaluation']),
            'order_sensitive_ids': [c['id'] for c in cases if len({r['choice'] for r in orders
                if r['id'] == c['id']}) > 1],
            'batch_choice_changed_ids': [r['id'] for r in orders if r['order_index'] == 0
                and r['choice'] != primary_choices[r['id']]],
            'repeat_choice_changed_ids': sorted({r['id'] for r in rows
                if r['phase'] == 'repeat' and r['prompt'] == prompt
                and r['choice'] != primary_choices[r['id']]}) if prompt in ('ja', 'candidate_ja') else None,
        }
    return summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env', type=Path, default=ROOT / '.env')
    parser.add_argument('--cases', type=Path, default=ROOT / 'tools/laya-eval/cases.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/jev-eval/results.json')
    parser.add_argument('--limit', type=int, help='動作確認用のHTTP要求上限。再開時は既存分も含む')
    args = parser.parse_args()
    cases = json.loads(args.cases.read_text())['cases']
    validate_cases(cases)
    jobs = build_jobs(cases, MODEL)
    key = load_key(args.env)
    import httpx
    metadata = {'model': MODEL, 'endpoint': ENDPOINT, 'seed': 20261011,
                'cases_sha256': fingerprint(args.cases),
                'script_sha256': fingerprint(Path(__file__)),
                'shared_script_sha256': fingerprint(ROOT / 'scripts/punctuation_eval.py'),
                'prompts': PROMPTS, 'python': platform.python_version(),
                'httpx': importlib.metadata.version('httpx'),
                'expected_requests': len(jobs),
                'expected_answers': sum(len(job['items']) for job in jobs)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checkpoint = args.output.with_suffix('.jsonl')
    records = read_checkpoint(checkpoint, metadata)
    for record in records:
        expected = next((j for j in jobs if j['job_id'] == record['job_id']), None)
        if expected is None or record['request'] != expected['request']:
            raise ValueError('再開用記録の要求が異なる')
        record['rows'] = decode_rows(record)
    if not checkpoint.exists():
        checkpoint.write_text(safe_json({'metadata': metadata}, key) + '\n')
    done = {record['job_id'] for record in records}
    # リダイレクトでキーを別ホストへ送らず、HTTP接続を再利用する。
    with httpx.Client(timeout=30, follow_redirects=False) as client, checkpoint.open('a') as stream:
        for job in jobs[:args.limit]:
            if job['job_id'] in done:
                continue
            record = {**job, 'recorded_at': datetime.now(timezone.utc).isoformat(),
                      'script_sha256': metadata['script_sha256'],
                      **run_request(client, job['request'], key)}
            # 検証前に応答を保存し、形式エラーでも証拠や使用量を失わない。
            stream.write(safe_json(record, key) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
            record['rows'] = decode_rows(record)
            records.append(record)
            if len(records) % 25 == 0 or len(records) == len(jobs):
                print(f'完了: {len(records)}/{len(jobs)} HTTP要求', flush=True)
    complete = len(records) == len(jobs)
    with checkpoint.open() as stream:
        checkpoint_metadata = json.loads(next(stream))['metadata']
    payload = {'metadata': metadata, 'checkpoint_metadata': checkpoint_metadata,
               'complete': complete, 'requests': records,
               'usage': {key: sum(record['result']['usage'][key] for record in records)
                         for key in ('input_tokens', 'output_tokens')},
               'summaries': summarize_records(cases, records) if complete else None}
    args.output.write_text(safe_json(payload, key) + '\n')
    print(json.dumps({'complete': complete, 'requests': len(records),
                      'usage': payload['usage'], 'summaries': payload['summaries']},
                     ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # ライブラリ例外に含まれうる要求情報は表示しない。成功済み要求は再開時に再利用する。
        print(f'評価停止: {type(error).__name__}。キーを含まない記録と設定を確認してください。', flush=True)
        raise SystemExit(1) from None
