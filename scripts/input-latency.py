#!/usr/bin/env python3
"""収録終了時の発話・入力遅延と長い待ちの内訳を、許可した数値だけで表示する。"""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
from uuid import UUID

PREFIXES=('inputQueueWait','inputIssueDuration','recognitionToIssue')
COUNTS={'inputPublications','inputPartialPublications','inputRewrittenCharacters'}
EXTRA_COUNTS={'inputLocalizedPublications','inputPreservedCharacters'}
TIMINGS={prefix+suffix for prefix in PREFIXES for suffix in ('P50','P95','Max')}
KINDS=COUNTS | EXTRA_COUNTS | TIMINGS | {'firstInputIssued','preparing','latencyDetails'}
WINDOWS=('interim','final','captureLag','rawQueue','conversion','frameLength','sampleRate','callbackInterval')
SPEECH_FIELDS={'firstSpeechToResult','timelineValid','unmeasuredResults'} | {prefix+suffix for prefix in WINDOWS for suffix in ('P50','P95','Max','Count')}
INPUT_FIELDS={'total','handoff','transform','queue','previousIssue','scheduledWait','timerOverrun','worker',
              'issue','focus','eventPost','cooperativeYield','rangeEdit','sinkOther','deleted','inserted','preserved','completed','isFinal','recognitionSource',
              'localizedStage','localizedReason','localizedWaits','localizedIssued','localizedFallback'}
SUMMARY_FIELDS={'localizedAttempts','localizedCompletions','localizedUnavailable','localizedStops','localizedWaits','correctionEvents','maximumRewrite'}
SUMMARY_OPTIONAL={'localizedEligible','localizedCostSkipped','localizedBelowThreshold','localizedInsufficientSuffix','localizedReplacementTooLong'}
FLAGS={'timelineValid','completed','isFinal','recognitionSource','localizedIssued','localizedFallback'}
LOCALIZED_STAGES={1:'変更前照合',2:'選択設定',3:'選択確認',4:'文字発行',5:'置換確認',6:'カーソル復帰',7:'復帰確認',8:'完了'}
LOCALIZED_REASONS={0:'なし',1:'未対応',2:'本文取得不可',3:'入力先変更',4:'取消・許可失効',5:'本文不一致',6:'選択不一致',7:'期限超過',8:'選択設定失敗',9:'発行拒否',10:'処理中',11:'費用未計測',12:'費用上の利益なし'}

def valid_number(value,maximum):
    return type(value) in (int,float) and math.isfinite(value) and 0<=value<=maximum

def read_details(row):
    details=row.get('details')
    if not isinstance(details,dict):return None
    try:session=str(UUID(details.get('session')))
    except (ValueError,TypeError,AttributeError):return None
    stage=details.get('stage');samples=details.get('samples')
    if stage not in ('speech','input','inputFailures','inputSummary') or not isinstance(samples,list):return None
    if len(samples)> (1 if stage in ('speech','inputSummary') else 8) or row['count']!=len(samples):return None
    allowed=SPEECH_FIELDS if stage=='speech' else SUMMARY_FIELDS | SUMMARY_OPTIONAL if stage=='inputSummary' else INPUT_FIELDS
    clean=[]
    for sample in samples:
        if not isinstance(sample,dict) or type(sample.get('sequence')) is not int or not 0<=sample['sequence']<=1000000:return None
        fields=sample.get('values')
        if not isinstance(fields,dict):return None
        values={key:value for key,value in fields.items() if key in allowed}
        for key,value in values.items():
            maximum=1 if key in FLAGS else 512 if key.endswith('Count') else 1000000 if key in SUMMARY_FIELDS | SUMMARY_OPTIONAL | {'deleted','inserted','preserved','unmeasuredResults'} else 86400000
            if not valid_number(value,maximum):return None
            if (key in FLAGS or maximum in (512,1000000)) and value!=int(value):return None
        if stage in ('input','inputFailures') and not {'total','queue','issue'}.issubset(values):return None
        if stage=='inputFailures' and values.get('completed')!=0:return None
        if stage=='inputSummary' and not SUMMARY_FIELDS.issubset(values):return None
        if 'localizedStage' in values and values['localizedStage'] not in LOCALIZED_STAGES:return None
        if 'localizedReason' in values and values['localizedReason'] not in LOCALIZED_REASONS:return None
        if stage=='speech' and not {'timelineValid','unmeasuredResults'}.issubset(values):return None
        for prefix in WINDOWS:
            keys=[prefix+suffix for suffix in ('P50','P95','Max','Count')]
            if not any(key in values for key in keys):continue
            if not all(key in values for key in keys) or values[keys[-1]]<1:return None
            times=[values[key] for key in keys[:3]]
            if times!=sorted(times):return None
        clean.append({'sequence':sample['sequence'],'values':values})
    return {'session':session,'stage':stage,'samples':clean}

def complete(summary):
    if not COUNTS.issubset(summary):return False
    for prefix in PREFIXES:
        keys=[prefix+suffix for suffix in ('P50','P95','Max')]
        present=[key in summary for key in keys]
        if not any(present):
            if prefix!='recognitionToIssue' and summary['inputPublications']['count']>0:return False
            continue
        if not all(present):return False
        counts=[summary[key]['count'] for key in keys]
        values=[summary[key]['milliseconds'] for key in keys]
        if len(set(counts))!=1 or not 1<=counts[0]<=512 or counts[0]>summary['inputPublications']['count']:return False
        if values!=sorted(values):return False
    return True

def read_summaries(directory):
    records=[]
    for index in (2,1,0):
        path=directory/f'diagnostic-{index}.jsonl'
        try:
            if path.is_symlink() or not path.is_file() or path.stat().st_size>65536:continue
            for line in path.read_text().splitlines():
                try:row=json.loads(line)
                except (ValueError,TypeError):continue
                if not isinstance(row,dict):continue
                kind=row.get('kind');stamp=row.get('timestamp');count=row.get('count');milliseconds=row.get('milliseconds')
                if not isinstance(kind,str) or kind not in KINDS or not valid_number(stamp,1e12):continue
                if kind=='preparing':records.append((stamp,kind,0,0,None));continue
                if type(count) is not int or not 0<=count<=1000000 or not valid_number(milliseconds,86400000):continue
                details=read_details(row) if kind=='latencyDetails' else None
                if kind=='latencyDetails' and details is None:continue
                records.append((stamp,kind,count,milliseconds,details))
        except (OSError,UnicodeError):continue
    speech={details['session']:details for _,kind,_,_,details in records if kind=='latencyDetails' and details['stage']=='speech'}
    extras={(details['session'],details['stage']):details for _,kind,_,_,details in records
            if kind=='latencyDetails' and details['stage'] in ('inputFailures','inputSummary')}
    summaries=[];current={}
    for stamp,kind,count,milliseconds,details in sorted(records,key=lambda row:row[0]):
        if kind=='preparing':current={};continue
        if kind=='latencyDetails':
            if details['stage']=='input':current['inputDetails']=details
            continue
        if kind=='firstInputIssued' or (kind=='inputQueueWaitP50' and 'inputPublications' in current):current={}
        current[kind]={'count':count,'milliseconds':milliseconds}
        if kind=='inputRewrittenCharacters':
            if complete(current):
                session=current.get('inputDetails',{}).get('session')
                if session in speech:current['speechDetails']=speech[session]
                for stage in ('inputFailures','inputSummary'):
                    if (session,stage) in extras:current[stage]=extras[session,stage]
                summaries.append({'timestamp':stamp,**current})
            current={}
    return summaries

def format_summary(summary):
    stamp=datetime.fromtimestamp(summary['timestamp']).astimezone().isoformat(timespec='seconds')
    lines=[f"{stamp} / 完了発行 {summary['inputPublications']['count']}回 / 未完了 {summary['inputPartialPublications']['count']}回 / 削除 {summary['inputRewrittenCharacters']['count']}文字"]
    if EXTRA_COUNTS.issubset(summary):lines.append(f"  範囲置換 {summary['inputLocalizedPublications']['count']}回 / 削除・再入力を省いた末尾 {summary['inputPreservedCharacters']['count']}文字（発行済み、未完了を含む）")
    if 'firstInputIssued' in summary:lines.append(f"  最初の認識結果の受付 → 初回発行完了: {summary['firstInputIssued']['milliseconds']:.2f}")
    for prefix,label in zip(PREFIXES,('キュー待ち','OS発行処理','認識結果の受付 → 発行完了')):
        if prefix+'P50' not in summary:continue
        values=[summary[prefix+suffix]['milliseconds'] for suffix in ('P50','P95','Max')]
        lines.append(f"  {label}: p50 {values[0]:.2f} / p95 {values[1]:.2f} / 最大 {values[2]:.2f} / 標本 {summary[prefix+'P50']['count']}")
    def number(fields,key):return f'{fields[key]:.2f}' if key in fields else '未計測'
    speech=summary.get('speechDetails',{}).get('samples',[])
    if speech:
        fields=speech[0]['values']
        lines.append(f"  発話先頭 → 初回認識結果: {number(fields,'firstSpeechToResult')}（音声区間からの推定）")
        for prefix,label in zip(WINDOWS,('発話末尾 → 途中結果','発話末尾 → 確定結果','収録バッファ末尾 → tap到着','tap到着 → 変換開始','音量計算・音声変換','実フレーム長（frame）','サンプルレート（Hz）','tap間隔')):
            if prefix+'Count' not in fields:lines.append(f'  {label}: 未計測');continue
            lines.append(f"  {label}: p50 {fields[prefix+'P50']:.2f} / p95 {fields[prefix+'P95']:.2f} / 最大 {fields[prefix+'Max']:.2f} / 標本 {fields[prefix+'Count']:g}")
        state='連続' if fields['timelineValid']==1 else '欠落または不連続（有効時点の標本のみ）'
        lines.append(f"  時刻対応: {state} / 計測できなかった認識結果 {fields['unmeasuredResults']:g}件")
    else:lines.append('  発話 → 認識: 詳細計測なし（旧版またはログ欠落）')
    operations=summary.get('inputSummary',{}).get('samples',[])
    if operations:
        f=operations[0]['values']
        lines.append(f"  局所置換: 試行 {f['localizedAttempts']:g} / 完了 {f['localizedCompletions']:g} / 未対応 {f['localizedUnavailable']:g} / 停止 {f['localizedStops']:g} / 反映待ち {f['localizedWaits']:g}")
        if 'localizedEligible' in f:lines.append(f"  局所置換の候補 {f['localizedEligible']:g} / 費用条件による見送り {f.get('localizedCostSkipped',0):g}")
        if 'localizedBelowThreshold' in f:lines.append(f"  候補外: 小さい訂正 {f['localizedBelowThreshold']:g} / 共通末尾不足 {f.get('localizedInsufficientSuffix',0):g} / 置換長超過 {f.get('localizedReplacementTooLong',0):g}")
        lines.append(f"  書き換え: {f['correctionEvents']:g}回 / 一回の最大 {f['maximumRewrite']:g}文字")
    failures=summary.get('inputFailures',{}).get('samples',[])
    for sample in failures:
        f=sample['values']
        stage=LOCALIZED_STAGES.get(f.get('localizedStage'),'通常発行')
        reason=LOCALIZED_REASONS.get(f.get('localizedReason'),'詳細なし')
        lines.append(f"  未完了 #{sample['sequence']}: {stage} / {reason} / 待機 {f.get('localizedWaits',0):g}回 / 局所文字発行 {f.get('localizedIssued',0):g}")
    details=summary.get('inputDetails')
    if details is None:lines.append('  長い入力待ち: 詳細計測なし（旧版またはログ欠落）')
    elif not details['samples']:lines.append('  長い入力待ち: 対象なし')
    else:
        lines.append('  長い入力待ち: 収録全体の遅い順、最大8件（完了・未完了を含む）')
        for sample in details['samples']:
            fields=sample['values'];n=lambda key:number(fields,key)
            origin='認識結果' if fields.get('recognitionSource')==1 else '補正など'
            status='完了' if fields.get('completed')==1 else '未完了' if 'completed' in fields else '状態不明'
            lines.append(f"    #{sample['sequence']} {origin} / {status} / 合計 {n('total')} / 削除 {n('deleted')}文字 / 挿入 {n('inserted')}文字")
            lines.append(f"      結果の受け渡し {n('handoff')} + 辞書・整形 {n('transform')} + キュー {n('queue')} + OS発行 {n('issue')}")
            lines.append(f"      キュー内訳: 前の発行待ち {n('previousIssue')} / 意図した待機 {n('scheduledWait')} / タイマー超過 {n('timerOverrun')} / その他の処理・再開待ち {n('worker')}")
            lines.append(f"      OS発行内訳: 入力先確認 {n('focus')} / イベント発行 {n('eventPost')} / 処理の譲渡・再開待ち {n('cooperativeYield')} / 範囲照合・選択・反映確認 {n('rangeEdit')} / その他 {n('sinkOther')}")
    return '\n'.join(lines)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',type=Path,default=Path.home()/'Library/Logs/forblaze')
    parser.add_argument('--sessions',type=int,default=5)
    parser.add_argument('--json',action='store_true')
    args=parser.parse_args()
    if not 1<=args.sessions<=100:parser.error('sessionsは1〜100')
    summaries=read_summaries(args.directory)[-args.sessions:]
    if args.json:print(json.dumps(summaries,ensure_ascii=False,indent=2));return
    if not summaries:print('入力遅延の集計はまだありません。対応版で音声入力を開始し、終了してから確認してください。');return
    print('単位: ms。各集計の直近512標本以内（p95はnearest-rank）。入力集計は完了した発行のみ。')
    print('発話時刻は認識された音声区間からの推定。認識結果はアプリが受信した時点、OS発行は入力先の表示完了前です。')
    print('異なる集計の最大値は別の標本なので足せません。長い入力待ちの各内訳は同じ更新に対応します。')
    for summary in summaries:
        print('\n'+format_summary(summary))

if __name__=='__main__':main()
