#!/usr/bin/env python3
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import uuid
ROOT=Path(__file__).resolve().parent.parent
BUNDLE_ID='dev.kazuki-oshino.forblaze'
def check_bundle(path):
    if path.is_symlink():raise ValueError('アプリのリンクは設置対象にできない')
    with (path/'Contents/Info.plist').open('rb') as handle:info=plistlib.load(handle)
    if info.get('CFBundleIdentifier')!=BUNDLE_ID:raise ValueError('Bundle IDが一致しない')
    executable=path/'Contents/MacOS/forblaze'
    if not executable.is_file() or executable.is_symlink():raise ValueError('実行ファイルが不正')
def verify_signature(path):
    check_bundle(path)
    subprocess.run(['codesign','--verify','--deep','--strict',str(path)],check=True)
    result=subprocess.run(['codesign','-dv','--verbose=4',str(path)],capture_output=True,text=True,check=True)
    if 'Identifier='+BUNDLE_ID not in result.stderr or 'Authority=Apple Development:' not in result.stderr:
        raise ValueError('継続可能なApple Development署名が必要（アドホック不可）')
def install(source,destination,allowed_parent,verify=verify_signature,copy=shutil.copytree,move=lambda src,dst:src.rename(dst)):
    source=Path(source);destination=Path(destination);parent=Path(allowed_parent)
    if destination.name!='forblaze.app' or destination.parent.resolve()!=parent.resolve() or destination.is_symlink():
        raise ValueError('forblaze専用の設置先だけを許可する')
    check_bundle(source)
    if destination.exists():check_bundle(destination)
    verify(source)
    parent.mkdir(parents=True,exist_ok=True)
    token=uuid.uuid4().hex
    stage=parent/('.forblaze-stage-'+token+'.app')
    backup=parent/('.forblaze-backup-'+token+'.app')
    # 以下の削除対象は、この操作で作成したstageとbackupだけ。
    try:
        copy(source,stage);verify(stage)
        if destination.exists():move(destination,backup)
        try:move(stage,destination)
        except BaseException:
            if backup.exists():move(backup,destination)
            raise
    finally:
        if stage.exists():shutil.rmtree(stage)
    if backup.exists():shutil.rmtree(backup)
def signing_check():
    identity=os.environ.get('FORBLAZE_SIGNING_IDENTITY')
    if not identity:raise ValueError('FORBLAZE_SIGNING_IDENTITYへApple Development署名IDを設定してください')
    source=ROOT/'build/DerivedData/Build/Products/Debug/forblaze.app'
    check_bundle(source)
    parent=ROOT/'build/Signed';parent.mkdir(parents=True,exist_ok=True)
    stage=parent/('.forblaze-sign-'+uuid.uuid4().hex+'.app')
    try:
        shutil.copytree(source,stage)
        subprocess.run(['codesign','--force','--deep','--options','runtime','--timestamp=none','--entitlements',str(ROOT/'Forblaze/forblaze.entitlements'),'--sign',identity,str(stage)],check=True)
        verify_signature(stage)
        install(stage,parent/'forblaze.app',allowed_parent=parent)
    finally:
        if stage.exists():shutil.rmtree(stage)
    print('署名確認成功: '+str(parent/'forblaze.app'))
def main():
    action=sys.argv[1]
    if action=='signing-check':signing_check()
    elif action=='install':
        install(ROOT/'build/Signed/forblaze.app',Path('/Applications/forblaze.app'),allowed_parent=Path('/Applications'))
        print('/Applications/forblaze.appへ設置しました')
    elif action=='run':
        target=Path('/Applications/forblaze.app');verify_signature(target)
        subprocess.run(['open',str(target)],check=True)
    else:raise ValueError('不明な操作')
if __name__=='__main__':main()
