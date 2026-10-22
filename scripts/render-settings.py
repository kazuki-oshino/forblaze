#!/usr/bin/env python3
"""実サービスを起動せず、本番の設定画面を描画する。--live で操作確認。"""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
ROOT=Path(__file__).resolve().parent.parent
subprocess.run(['swift','build','--package-path',str(ROOT/'Packages/ForblazeKit')],cwd=ROOT,check=True)
folder=Path(subprocess.check_output(['swift','build','--package-path',str(ROOT/'Packages/ForblazeKit'),'--show-bin-path'],text=True).strip())
output=ROOT/'build/settings-preview';output.mkdir(parents=True,exist_ok=True)
bundle=output/'ForblazeSettingsPreview.app';contents=bundle/'Contents';binary=contents/'MacOS/ForblazeSettingsPreview'
binary.parent.mkdir(parents=True,exist_ok=True)
resources=contents/'Resources';resources.mkdir(parents=True,exist_ok=True)
shutil.copyfile(ROOT/'Forblaze/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png',resources/'AppIcon.png')
with (contents/'Info.plist').open('wb') as handle:
    plistlib.dump({'CFBundleIdentifier':'dev.kazuki-oshino.forblaze.settings-preview','CFBundleExecutable':binary.name,'CFBundleName':'ForblazeSettingsPreview','CFBundlePackageType':'APPL'},handle)
objects=sorted((folder/'ForblazeCore.build').glob('*.o'))+sorted((folder/'ForblazeApplication.build').glob('*.o'))
sources=sorted((ROOT/'Forblaze/Features/Settings').glob('*.swift'))+[ROOT/'Forblaze/Presentation/TextEditingMenu.swift',ROOT/'tools/settings-preview/main.swift']
subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-target','arm64-apple-macosx26.0','-I',str(folder/'Modules'),*[str(p) for p in sources+objects],'-o',str(binary)],cwd=ROOT,check=True)
subprocess.run([str(binary),str(output),*sys.argv[1:]],cwd=ROOT,check=True)
print('描画結果: '+str(output))
