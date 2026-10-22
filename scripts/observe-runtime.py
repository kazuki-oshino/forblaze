#!/usr/bin/env python3
"""設置済みforblazeのRSSと型付き数値だけを採取する。合否は判定しない。"""
import argparse
import csv
import json
import math
from pathlib import Path
import plistlib
import subprocess
import time

ROOT=Path(__file__).resolve().parent.parent
APP=Path('/Applications/forblaze.app')
EXECUTABLE=str(APP/'Contents/MacOS/forblaze')
COUNTS=('rawAudioQueuePeak','analyzerInputQueuePeak','recognitionQueuePeak','audioStreams','resultStreams','captureRunning','inputPending')
PHASES={'preparing','listening','suspended','finishing','stopping','idle'}

def find_pid(output):
    matches=[]
    for line in output.splitlines():
        parts=line.strip().split(maxsplit=1)
        if len(parts)==2 and parts[0].isdigit() and parts[1]==EXECUTABLE:matches.append(int(parts[0]))
    if len(matches)!=1:raise ValueError('設置済みforblazeが1プロセスだけ起動している必要があります')
    return matches[0]

def parse_rss(output):
    parts=output.strip().split(maxsplit=1)
    if len(parts)!=2 or not parts[0].isdigit() or parts[1]!=EXECUTABLE:
        raise ValueError('対象プロセスが終了または変化したため採取を停止します')
    return int(parts[0])

def read_diagnostics(directory,since):
    values=[]
    for index in range(3):
        path=directory/f'diagnostic-{index}.jsonl'
        if not path.is_file() or path.is_symlink() or path.stat().st_size>65536:continue
        try:
            for line in path.read_text().splitlines():
                try:row=json.loads(line)
                except (ValueError,TypeError):continue
                if not isinstance(row,dict):continue
                stamp=row.get('timestamp');kind=row.get('kind');count=row.get('count',0)
                if type(stamp) not in (int,float) or not math.isfinite(stamp) or stamp<since:continue
                if not isinstance(kind,str) or kind not in PHASES.union(COUNTS):continue
                if type(count) is not int or not 0<=count<=1000000:continue
                values.append((stamp,kind,count))
        except (OSError,UnicodeError):continue
    return sorted(values)

def command(*args):
    return subprocess.run(args,capture_output=True,text=True,check=True).stdout

def build_identifier():
    with (APP/'Contents/Info.plist').open('rb') as handle:info=plistlib.load(handle)
    if info.get('CFBundleIdentifier')!='dev.kazuki-oshino.forblaze':raise ValueError('Bundle IDが一致しません')
    value=info.get('ForblazeBuildIdentifier')
    if not isinstance(value,str) or len(value)!=16 or any(c not in '0123456789abcdef' for c in value):
        raise ValueError('ビルド指紋を確認できません')
    return value

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds',type=int,default=1800)
    parser.add_argument('--interval',type=int,default=10)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    if not 1<=args.seconds<=7200 or not 1<=args.interval<=60:parser.error('secondsは1〜7200、intervalは1〜60')
    build=build_identifier();pid=find_pid(command('ps','-axo','pid=,comm='))
    start=time.time();origin=time.monotonic()
    output=args.output or ROOT/'build/observations'/time.strftime('runtime-%Y%m%d-%H%M%S.csv')
    output.parent.mkdir(parents=True,exist_ok=True)
    counts={};phase='unknown';rows=0;minimum=None;maximum=0
    logs=Path.home()/'Library/Logs/forblaze'
    print(f'採取開始: PID {pid} / ビルド {build} / {output}',flush=True)
    print('普段の発話・停止・再開始と、最後の停止後の待機を含めてください。経過時間だけでは合格にしません。',flush=True)
    # 排他的に作成し、既存の観測を上書きしない。最大7201行。
    with output.open('x',newline='') as handle:
        writer=csv.writer(handle)
        writer.writerow(('timestamp','elapsedSeconds','pid','build','rssKiB','phase',*COUNTS))
        while True:
            if build_identifier()!=build:raise ValueError('設置版が変化したため採取を停止します')
            rss=parse_rss(command('ps','-p',str(pid),'-o','rss=,comm='))
            for _,kind,count in read_diagnostics(logs,start):
                if kind in PHASES:phase=kind
                else:counts[kind]=count
            elapsed=time.monotonic()-origin
            writer.writerow((round(time.time(),3),round(elapsed,3),pid,build,rss,phase,*(counts.get(k,'') for k in COUNTS)))
            handle.flush();rows+=1;minimum=rss if minimum is None else min(minimum,rss);maximum=max(maximum,rss)
            if elapsed>=args.seconds:break
            time.sleep(min(args.interval,args.seconds-elapsed))
    print(f'採取終了: {rows}件 / {elapsed:.1f}秒 / RSS {minimum}〜{maximum} KiB。合否は観測と実際の動作を合わせて判断します。')

if __name__=='__main__':
    try:main()
    except KeyboardInterrupt:print('採取を終了しました。既存の行は保持しています。')
    except (OSError,ValueError,subprocess.CalledProcessError) as error:
        raise SystemExit(f'採取できません: {error}')
